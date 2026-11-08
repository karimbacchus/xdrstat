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
    enum Kind: Int, CaseIterable { case cpu, memory, network, sensors }

    private let monitor = SystemMonitor.shared
    private let settings = AppSettings.shared
    private var items: [Kind: NSStatusItem] = [:]
    private var labelKeys: [Kind: String] = [:]
    private var bag = Set<AnyCancellable>()
    private var refreshScheduled = false

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
        let state = MonitorState(monitor, settings)
        // Create/remove in reverse so the left-to-right order is CPU, Memory, Network, Sensors.
        for k in Kind.allCases.reversed() {
            if isVisible(k) {
                if items[k] == nil { items[k] = makeItem(k) }
            } else if let item = items.removeValue(forKey: k) {
                if openKind == k { closePanel() }
                NSStatusBar.system.removeStatusItem(item)
                labelKeys[k] = nil
            }
        }
        for (k, item) in items { updateLabel(k, item, state) }
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

    /// Re-renders a label only when what it displays actually changed.
    private func updateLabel(_ k: Kind, _ item: NSStatusItem, _ st: MonitorState) {
        let key = labelKey(k, st)
        guard key != labelKeys[k], let button = item.button else { return }
        labelKeys[k] = key
        let image: NSImage
        switch k {
        case .cpu: image = MenuBarRender.image(CPUMenuLabelContent(state: st))
        case .memory: image = MenuBarRender.image(MemoryMenuLabelContent(state: st))
        case .network: image = MenuBarRender.image(NetworkMenuLabelContent(state: st))
        case .sensors: image = MenuBarRender.image(SensorsMenuLabelContent(state: st))
        }
        button.image = image
    }

    private func labelKey(_ k: Kind, _ st: MonitorState) -> String {
        let style = "\(st.style)"
        switch k {
        case .cpu:
            return style + "|\(Int((st.chip.cpu.usage * 100).rounded()))|"
                + st.chip.cpu.clusters.map { "\(Int($0.usage * 14))" }.joined(separator: ",")
        case .memory:
            return style + "|\(Int((st.memory.usedFraction * 100).rounded()))|\(Int(st.memory.pressure * 14))"
        case .network:
            var key = style + "|" + Fmt.rate(st.network.upBytesPerSec) + "|" + Fmt.rate(st.network.downBytesPerSec)
            if st.style == .graph { key += "|\(st.netDownHistory.values.count)" }   // graph scrolls every tick
            return key
        case .sensors:
            var key = style + "|" + SensorsMenuLabelContent.values(st).joined(separator: ",")
            if st.style == .graph { key += "|\(st.cpuTempHistory.values.count)|\(Int((st.cpuTempHistory.last ?? 0) * 2))" }
            return key
        }
    }

    // MARK: Panels

    /// QA hook: `XDRSTAT_OPEN=cpu|memory|network|sensors` opens that panel as if its item were clicked.
    func debugOpen(_ name: String) {
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
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Borderless, non-activating dropdown with menu vibrancy that sizes itself to its SwiftUI content
/// and stays pinned under its status item as the content grows or shrinks.
final class DropdownPanel: NSPanel {
    var anchor: NSRect = .zero
    private let host: SizingHostingView

    init(content: AnyView) {
        host = SizingHostingView(rootView: content)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        host.onSizeChange = { [weak self] in self?.reposition() }
    }

    override var canBecomeKey: Bool { true }    // lets the Sensors search field take typing
    override var canBecomeMain: Bool { false }

    /// Size to content (clamped to the screen) and hang the panel just under the status item.
    func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        let fit = host.fittingSize
        let size = NSSize(width: max(240, fit.width), height: min(max(80, fit.height), vis.height - 12))
        var x = anchor.midX - size.width / 2
        x = min(max(x, vis.minX + 6), vis.maxX - size.width - 6)
        let top = anchor.minY - 5
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if frame != self.frame { setFrame(frame, display: true) }
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
