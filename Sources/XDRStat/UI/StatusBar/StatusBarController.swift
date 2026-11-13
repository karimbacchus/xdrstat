// AppKit menu bar hosting. OWNER: lead.
//
// Why not SwiftUI MenuBarExtra: its labels live in the App scene graph, so a label that changes
// every second makes SwiftUI rebuild the app (incl. the main menu) every second. On macOS 27 that
// leaked ~1 GB/hour and eventually pinned the main thread, so panels never opened. Here labels are
// plain NSImages on NSStatusItems, and each panel is an NSPanel hosting SwiftUI only while open.

import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    typealias Kind = LabelKind

    private let monitor = SystemMonitor.shared
    private let settings = AppSettings.shared
    private var items: [Kind: NSStatusItem] = [:]
    /// Pixels of the image each item currently shows; AppKit is only touched when they change.
    private var shownPixels: [Kind: Data] = [:]
    private var bag = Set<AnyCancellable>()
    private var refreshScheduled = false
    /// Nobody can see the menu bar while the displays sleep or another user's session is active,
    /// so label work is skipped then (and caught up on wake).
    private var screensAsleep = false, sessionInactive = false
    private var labelsPaused: Bool { screensAsleep || sessionInactive }

    private var panel: DropdownPanel?
    private var openKind: Kind?
    private var eventMonitors: [Any] = []
    private var settingsWindow: NSWindow?

    override init() {
        super.init()
        PanelActions.close = { [weak self] in self?.closePanel() }
        PanelActions.openSettings = { [weak self] in self?.showSettings() }

        // Coalesce all model changes into at most one label refresh per run-loop pass.
        monitor.objectWillChange.merge(with: settings.objectWillChange)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &bag)

        let flags: [(Notification.Name, ReferenceWritableKeyPath<StatusBarController, Bool>, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, \.screensAsleep, true),
            (NSWorkspace.screensDidWakeNotification, \.screensAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, \.sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, \.sessionInactive, false)]
        for (name, flag, value) in flags {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self else { return }
                    let wasPaused = self.labelsPaused
                    self[keyPath: flag] = value
                    if wasPaused && !self.labelsPaused { self.refresh() }
                }
                .store(in: &bag)
        }
        refresh()
    }

    // MARK: Status items

    private func isVisible(_ k: Kind) -> Bool {
        let s = settings
        let any = s.showCPU || s.showMemory || s.showNetwork || s.showSensors
        if !any { return k == .cpu }   // never let every item disappear
        switch k {
        case .cpu: return s.showCPU
        case .memory: return s.showMemory
        case .network: return s.showNetwork
        case .sensors: return s.showSensors
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // objectWillChange fires *before* the new value is stored; read it on the next pass.
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        // Create/remove in reverse so the left-to-right order is CPU, Memory, Network, Sensors.
        for k in Kind.allCases.reversed() {
            if isVisible(k) {
                if items[k] == nil { items[k] = makeItem(k) }
            } else if let item = items.removeValue(forKey: k) {
                if openKind == k { closePanel() }
                NSStatusBar.system.removeStatusItem(item)
                shownPixels[k] = nil
            }
        }
        guard !labelsPaused else { return }
        let state = MonitorState(monitor, settings)
        // Render for the sharpest attached display; AppKit scales down for the others.
        let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        for (k, item) in items { updateLabel(k, item, state, scale: scale) }
    }

    private func makeItem(_ k: Kind) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "xdrstat.\(k)"
        if let b = item.button {
            b.tag = k.rawValue
            b.target = self
            b.action = #selector(itemClicked(_:))
            b.sendAction(on: [.leftMouseDown, .rightMouseDown])
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel(["CPU", "Memory", "Network", "Sensors"][k.rawValue])
        }
        return item
    }

    /// Redraws a label (cheap) and hands it to AppKit only if the pixels changed (expensive: AppKit
    /// re-lays out and re-snapshots the item). An idle network graph or a steady temperature costs nothing.
    private func updateLabel(_ k: Kind, _ item: NSStatusItem, _ st: MonitorState, scale: CGFloat) {
        guard let button = item.button else { return }
        let r = MenuBarLabel.render(k, st, scale: scale)
        guard r.pixels != shownPixels[k] else { return }
        shownPixels[k] = r.pixels
        button.image = r.image
        button.setAccessibilityLabel(r.accessibility)
    }

    // MARK: Panels

    /// QA hook: `XDRSTAT_OPEN=cpu|memory|network|sensors` opens that panel as if its item were clicked
    /// (`XDRSTAT_OPEN=close` closes it again).
    func debugOpen(_ name: String) {
        if name == "close" { closePanel(); return }
        if name == "settings" { showSettings(); return }
        let names = ["cpu", "memory", "network", "sensors"]
        guard let i = names.firstIndex(of: name), let k = Kind(rawValue: i), let b = items[k]?.button else { return }
        itemClicked(b)
    }

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        guard let k = Kind(rawValue: sender.tag) else { return }
        if openKind == k { closePanel() } else { openPanel(k, from: sender) }
    }

    private func panelView(_ k: Kind) -> AnyView {
        let v: AnyView
        switch k {
        case .cpu: v = AnyView(CPUPanel())
        case .memory: v = AnyView(MemoryPanel())
        case .network: v = AnyView(NetworkPanel())
        case .sensors: v = AnyView(SensorsPanel())
        }
        return AnyView(v.environmentObject(monitor).environmentObject(settings))
    }

    private func openPanel(_ k: Kind, from button: NSStatusBarButton) {
        closePanel()
        guard let buttonWindow = button.window else { return }
        let p = DropdownPanel(content: panelView(k))
        p.anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        p.reposition()
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
        openKind = k
        button.highlight(true)
        // SwiftUI finishes its first layout pass after the window is on screen; re-measure then.
        DispatchQueue.main.async { [weak p] in p?.reposition() }

        // Close on any click outside our app (other apps, desktop, menu bar)...
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.closePanel()
        }) { eventMonitors.append(m) }
        // ...on clicks in this app's other windows (e.g. Settings), but not on our status items,
        // whose own action toggles the panel...
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self, let w = e.window else { return e }
            if let p = self.panel, w === p {
                // The panel's window extends past the glass to hold its shadow; a click out there is outside.
                if !p.panelFrame.contains(NSEvent.mouseLocation) { self.closePanel() }
            } else if !w.className.contains("StatusBar") {
                self.closePanel()
            }
            return e
        }) { eventMonitors.append(m) }
        // ...and on Escape.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.closePanel(); return nil }
            return e
        }) { eventMonitors.append(m) }
    }

    func closePanel() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        if let k = openKind { items[k]?.button?.highlight(false) }
        // Ordering out + dropping the hosting view fires onDisappear, which turns detailed sampling off.
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        openKind = nil
    }

    // MARK: Settings window

    private func showSettings() {
        closePanel()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(monitor).environmentObject(settings))
            let w = NSWindow(contentViewController: host)
            w.title = "XDRStat Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        // Accessory app with non-activating panels: plain activate() can be refused, this one is forced.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}

/// Borderless, non-activating dropdown that sizes itself to its SwiftUI content and stays pinned under its
/// status item as the content grows or shrinks. Backed by Liquid Glass, like the system's own menu
/// bar panels.
final class DropdownPanel: NSPanel {
    var anchor: NSRect = .zero
    private let host: SizingHostingView
    private let root = ShadowRingView()

    /// The window is larger than the visible panel by this much on every side, to leave room for the shadow.
    static let shadowMargin: CGFloat = 36

    init(content: AnyView) {
        host = SizingHostingView(rootView: content)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        // The standard window shadow can't follow a glass shape (it outlines the window's rectangle),
        // so the panel draws its own soft shadow around the glass instead.
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow

        host.translatesAutoresizingMaskIntoConstraints = false
        let backing = NSGlassEffectView()
        backing.cornerRadius = Theme.panelCornerRadius
        backing.contentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
            host.topAnchor.constraint(equalTo: backing.topAnchor),
            host.bottomAnchor.constraint(equalTo: backing.bottomAnchor),
        ])
        root.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        backing.frame = root.bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        backing.autoresizingMask = [.width, .height]
        root.addSubview(backing)
        contentView = root
        host.onSizeChange = { [weak self] in self?.reposition() }
    }

    override var canBecomeKey: Bool { true }    // lets the Sensors search field take typing
    override var canBecomeMain: Bool { false }

    /// The visible panel (the glass), in screen coordinates.
    var panelFrame: NSRect { frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    /// Size to content (clamped to the screen) and hang the panel just under the status item.
    func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        let fit = host.fittingSize
        let size = NSSize(width: max(240, fit.width), height: min(max(80, fit.height), vis.height - 12))
        var x = anchor.midX - size.width / 2
        x = min(max(x, vis.minX + 6), vis.maxX - size.width - 6)
        let top = anchor.minY - 5
        let panel = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        let frame = panel.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin)
        if frame != self.frame { setFrame(frame, display: true) }
    }
}

/// Draws a soft drop shadow around an inset rounded rectangle and nothing inside it, so the shadow never
/// shows through the translucent panel it surrounds.
private final class ShadowRingView: NSView {
    private let shadowLayer = CALayer()
    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.30
        shadowLayer.shadowRadius = 18
        shadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        ring.fillRule = .evenOdd
        shadowLayer.mask = ring
        layer?.addSublayer(shadowLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let m = DropdownPanel.shadowMargin, r = Theme.panelCornerRadius
        let hole = CGPath(roundedRect: bounds.insetBy(dx: m, dy: m), cornerWidth: r, cornerHeight: r, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(hole)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // follow the window's frame exactly, no implicit animation
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = hole
        ring.frame = bounds
        ring.path = outside
        CATransaction.commit()
    }
}

final class SizingHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?
    private var pending = false

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.onSizeChange?()
        }
    }
}
