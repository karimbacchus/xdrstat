import SwiftUI
import AppKit
import ImageIO

/// QA helper: `XDRSTAT_SNAPSHOT=/some/dir XDRStat` renders every panel / label / settings to PNGs and exits.
@MainActor enum SnapshotRunner {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["XDRSTAT_SNAPSHOT_SITE"] != nil {
            site(into: dir)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["XDRSTAT_SNAPSHOT_LIVE"] != nil {
            // Render with real data after letting the samplers warm up and fill history.
            let m = SystemMonitor.shared
            m.detail = DetailFlags(cpu: true, memory: true, network: true, sensors: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                let live = MonitorState(m, AppSettings.shared)
                panel(CPUPanelContent(state: live), "live-cpu", .dark, dir)
                panel(MemoryPanelContent(state: live), "live-memory", .dark, dir)
                panel(NetworkPanelContent(state: live), "live-network", .dark, dir)
                panel(SensorsPanelContent(state: live, initiallyExpanded: ["T-CPU"]), "live-sensors", .dark, dir)
                labels(live, dir)
                exit(0)
            }
            return
        }
        let mock = MockData.state
        let empty = MonitorState()

        for scheme in [ColorScheme.dark, .light] {
            let tag = scheme == .dark ? "dark" : "light"
            panel(CPUPanelContent(state: mock), "cpu-\(tag)", scheme, dir)
            panel(MemoryPanelContent(state: mock), "memory-\(tag)", scheme, dir)
            panel(NetworkPanelContent(state: mock), "network-\(tag)", scheme, dir)
            panel(SensorsPanelContent(state: mock, initiallyExpanded: ["T-CPU"]), "sensors-\(tag)", scheme, dir)
        }
        panel(CPUPanelContent(state: empty), "cpu-empty", .dark, dir)
        panel(MemoryPanelContent(state: empty), "memory-empty", .dark, dir)
        panel(NetworkPanelContent(state: empty), "network-empty", .dark, dir)
        panel(SensorsPanelContent(state: empty), "sensors-empty", .dark, dir)
        labels(mock, dir)
        exit(0)
    }

    /// Website screenshots: demo data (no real addresses/apps), real icons, 3x, panel-shaped.
    private static func site(into dir: String) {
        SnapshotOptions.realIcons = true
        let st = MockData.state
        func shot<V: View>(_ v: V, _ name: String) {
            // AppKit rendering (ImageRenderer washes out the whole image once a bitmap icon is present).
            let root = v.environment(\.isSnapshot, true)
                .background(Color(red: 0.13, green: 0.135, blue: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            let host = NSHostingView(rootView: AnyView(root))
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.isOpaque = false; win.backgroundColor = .clear
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded(); host.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let scale: CGFloat = 3
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("wrote \(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
        shot(CPUPanelContent(state: st), "panel-cpu")
        shot(MemoryPanelContent(state: st), "panel-memory")
        shot(NetworkPanelContent(state: st), "panel-network")
        shot(SensorsPanelContent(state: st), "panel-sensors")
        // Menu bar labels, white on transparent (dark menu bar look).
        func label<V: View>(_ v: V, _ name: String) {
            let r = ImageRenderer(content: v.frame(height: 22).foregroundStyle(.white).environment(\.colorScheme, .dark)); r.scale = 3; r.isOpaque = false
            guard let cg = r.cgImage else { return }
            let url = URL(fileURLWithPath: "\(dir)/\(name).png") as CFURL
            if let d = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
        }
        label(CPUMenuLabelContent(state: st), "label-cpu")
        label(MemoryMenuLabelContent(state: st), "label-memory")
        label(NetworkMenuLabelContent(state: st), "label-network")
        label(SensorsMenuLabelContent(state: st), "label-sensors")
    }

    private static func bg(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.15) : Color(white: 0.95) }

    private static func write(_ r: ImageRenderer<some View>, _ name: String, _ dir: String) {
        print("rendering \(name)"); fflush(stdout)
        r.scale = 2
        guard let cg = r.cgImage else { print("failed: \(name)"); return }
        let url = URL(fileURLWithPath: "\(dir)/\(name).png") as CFURL
        if let d = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
        }
        print("wrote \(name).png \(cg.width)x\(cg.height)")
    }

    private static func panel<V: View>(_ v: V, _ name: String, _ scheme: ColorScheme, _ dir: String, fixedWidth: Bool = true) {
        let view = v.environment(\.isSnapshot, true).environment(\.colorScheme, scheme)
            .background(bg(scheme)).fixedSize()
        write(ImageRenderer(content: view), name, dir)
    }

    private static func cg(_ v: some View, template: Bool) -> CGImage {
        let r = ImageRenderer(content: v.frame(height: 18).foregroundStyle(.black)); r.scale = 2
        return r.cgImage!
    }

    private static func labels(_ st: MonitorState, _ dir: String) {
        func row(_ style: MenuBarStyle, _ scheme: ColorScheme) -> some View {
            var s = st; s.style = style
            let fg: Color = scheme == .dark ? .white : .black
            return HStack(spacing: 14) {
                Image(decorative: cg(CPUMenuLabelContent(state: s), template: false), scale: 2)
                Image(decorative: cg(MemoryMenuLabelContent(state: s), template: false), scale: 2)
                Image(decorative: cg(NetworkMenuLabelContent(state: s), template: false), scale: 2)
                Image(decorative: cg(SensorsMenuLabelContent(state: s), template: false), scale: 2)
            }
            .modifier(InvertIf(on: scheme == .dark))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.85))
        }
        let all = VStack(alignment: .leading, spacing: 0) {
            ForEach([MenuBarStyle.graph, .text, .compact], id: \.self) { row($0, .dark) }
            ForEach([MenuBarStyle.graph, .text, .compact], id: \.self) { row($0, .light) }
        }.fixedSize()
        write(ImageRenderer(content: all), "labels", dir)
    }
}

private struct InvertIf: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View { if on { content.colorInvert() } else { content } }
}
