import SwiftUI
import AppKit
import ImageIO

/// QA helper: `XDRSTAT_SNAPSHOT=/some/dir XDRStat` renders every panel / label / settings to PNGs and exits.
@MainActor enum SnapshotRunner {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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
