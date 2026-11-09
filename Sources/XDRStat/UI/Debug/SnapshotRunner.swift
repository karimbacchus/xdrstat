import SwiftUI
import AppKit
import ImageIO

/// QA helper: `XDRSTAT_SNAPSHOT=/some/dir XDRStat` renders every panel and the menu bar labels to PNGs and exits.
/// Add XDRSTAT_SNAPSHOT_LIVE=1 for real data, XDRSTAT_SNAPSHOT_SETTINGS=1 for the Settings tabs, or
/// XDRSTAT_SNAPSHOT_SITE=1 for the website images.
@MainActor enum SnapshotRunner {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["XDRSTAT_SNAPSHOT_SETTINGS"] != nil {
            settings(into: dir)
            exit(0)
        }
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

    /// Renders a view through AppKit (NSHostingView + cacheDisplay) rather than ImageRenderer, which washes
    /// out the whole image once a bitmap icon is present and can't draw AppKit-backed controls.
    private static func appKitShot<V: View>(_ v: V, _ name: String, _ dir: String, scale: CGFloat, dark: Bool = true) {
        let host = NSHostingView(rootView: AnyView(v))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear
        win.appearance = appearance
        win.contentView = host
        host.layoutSubtreeIfNeeded(); host.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("wrote \(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// Settings tabs (QA).
    private static func settings(into dir: String) {
        func tab<V: View>(_ v: V, _ name: String) {
            appKitShot(v.environmentObject(SystemMonitor.shared).environmentObject(AppSettings.shared)
                .frame(width: 460, height: 360).background(Color(white: 0.16)), name, dir, scale: 2)
        }
        tab(GeneralSettings(), "settings-general")
        tab(NetworkSettings(), "settings-network")
        tab(AboutSettings(), "settings-about")
    }

    /// Website screenshots: demo data (no real addresses/apps), real icons, 3x, panel-shaped.
    private static func site(into dir: String) {
        SnapshotOptions.realIcons = true
        let st = MockData.state
        func shot<V: View>(_ v: V, _ name: String) {
            appKitShot(v.environment(\.isSnapshot, true)
                .background(Color(red: 0.13, green: 0.135, blue: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)), name, dir, scale: 3)
        }
        shot(CPUPanelContent(state: st), "panel-cpu")
        shot(MemoryPanelContent(state: st), "panel-memory")
        shot(NetworkPanelContent(state: st), "panel-network")
        shot(SensorsPanelContent(state: st), "panel-sensors")
        // Menu bar labels, white on transparent (dark menu bar look), centred on a 22 pt canvas (the site's
        // mock menu bar shows them at 22 px tall).
        for (k, name) in [(LabelKind.cpu, "label-cpu"), (.memory, "label-memory"), (.network, "label-network"), (.sensors, "label-sensors")] {
            let label = MenuBarLabel.render(k, st, scale: 3, color: .white).cgImage
            let h = 22 * 3, pad = (h - label.height) / 2
            let ctx = CGContext(data: nil, width: label.width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(label, in: CGRect(x: 0, y: pad, width: label.width, height: label.height))
            writePNG(ctx.makeImage()!, "\(dir)/\(name).png")
        }
    }

    static func writePNG(_ cg: CGImage, _ path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        if let d = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
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

    /// All label styles on a dark and a light menu bar, tinted the way AppKit tints template images.
    private static func labels(_ st: MonitorState, _ dir: String) {
        let scale: CGFloat = 2, gap: CGFloat = 14, padX: CGFloat = 12, rowH: CGFloat = 26
        var rows: [(images: [CGImage], dark: Bool)] = []
        for dark in [true, false] {
            for style in [MenuBarStyle.graph, .text, .compact] {
                var s = st; s.style = style
                rows.append((LabelKind.allCases.map { MenuBarLabel.render($0, s, scale: scale, color: dark ? .white : .black).cgImage }, dark))
            }
        }
        func rowWidth(_ imgs: [CGImage]) -> CGFloat {
            let content: CGFloat = imgs.reduce(0) { $0 + CGFloat($1.width) / scale }
            return content + gap * CGFloat(imgs.count - 1) + 2 * padX
        }
        let width = rows.map { rowWidth($0.images) }.max() ?? 1
        let height = rowH * CGFloat(rows.count)
        let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        for (i, r) in rows.enumerated() {
            let y = height - rowH * CGFloat(i + 1)
            ctx.setFillColor(CGColor(gray: r.dark ? 0.1 : 0.85, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: rowH))
            var x = padX
            for img in r.images {
                let w = CGFloat(img.width) / scale, h = CGFloat(img.height) / scale
                ctx.draw(img, in: CGRect(x: x, y: y + (rowH - h) / 2, width: w, height: h))
                x += w + gap
            }
        }
        writePNG(ctx.makeImage()!, "\(dir)/labels.png")
        print("wrote labels.png")
    }
}
