import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Fixed-width panel frame; scrolls only when taller than the screen allows.
struct PanelFrame<Content: View>: View {
    var maxHeight: CGFloat? = nil
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var snapshot
    @LocalState private var measured: CGFloat = 0

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: Theme.pad) { content }
            .padding(Theme.pad)
            .frame(width: Theme.panelWidth, alignment: .leading)
        if snapshot {
            inner
        } else {
            let limit = maxHeight ?? ((NSScreen.main?.visibleFrame.height ?? 900) - 24)
            ScrollView(.vertical) {
                inner.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .onPreferenceChange(HeightKey.self) { measured = $0 }
            .frame(width: Theme.panelWidth, height: measured > 0 ? min(measured, limit) : 420)
        }
    }
}

struct SectionHeader: View {
    var title: String
    var detail: String? = nil
    var body: some View {
        CardTitle(title: title) {
            if let detail { Text(detail).font(Theme.mono12) }
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
}

struct HoverHighlight: ViewModifier {
    @LocalState private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .padding(.horizontal, -6).padding(.vertical, -3)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}
extension View { func hoverHighlight() -> some View { modifier(HoverHighlight()) } }

struct KeyValueRow: View {
    var label: String
    var value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(Theme.mono12).foregroundStyle(valueColor).lineLimit(1).truncationMode(.middle)
                .contentTransition(.numericText())
        }
        .hoverHighlight()
    }
}

/// Two-column grid of label/value stats.
struct StatGrid: View {
    var items: [(String, String)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 6) {
                    Text(it.0).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(it.1).font(Theme.mono12).lineLimit(1).minimumScaleFactor(0.8)
                }
                .hoverHighlight()
            }
        }
    }
}

struct LegendItem: View {
    var color: Color
    var name: String
    var value: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if let value { Text(value).font(Theme.mono11).foregroundStyle(.primary) }
        }
    }
}

struct EmptyHint: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 6)
    }
}

// MARK: - Process list

@MainActor enum ProcessIcons {
    private static var cache: [String: CGImage] = [:]
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)
    static func icon(pid: Int32, name: String, appPath: String? = nil) -> CGImage? {
        let key = appPath ?? "\(pid)-\(name)"
        if let i = cache[key] { return i }
        var img: NSImage?
        if let appPath { img = NSWorkspace.shared.icon(forFile: appPath) }
        else if let app = NSRunningApplication(processIdentifier: pid), let i = app.icon { img = i }
        else {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices"] {
                let p = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: p) { img = NSWorkspace.shared.icon(forFile: p); break }
            }
        }
        if cache.count > 300 { cache.removeAll() }
        var rect = NSRect(x: 0, y: 0, width: 40, height: 40)
        guard let cg = (img ?? generic).cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache[key] = cg
        return cg
    }
}

struct ProcessRow: View {
    @Environment(\.isSnapshot) private var snapshot
    var proc: ProcessUsage
    var value: (String, String)
    private var isSelf: Bool { proc.pid == ProcessInfo.processInfo.processIdentifier }
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if snapshot {
                    // ImageRenderer dims the whole render when a bitmap is present; use a placeholder in snapshots.
                    RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.gray.opacity(0.7), .gray.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                        .overlay(Text(String(proc.name.prefix(1))).font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                } else if let cg = ProcessIcons.icon(pid: proc.pid, name: proc.name, appPath: proc.appPath) {
                    // Canvas keeps ImageRenderer snapshots correct (plain Image dims the whole render).
                    Canvas { ctx, size in
                        ctx.draw(Image(decorative: cg, scale: 2), in: CGRect(origin: .zero, size: size))
                    }
                } else { Color.clear }
            }.frame(width: 16, height: 16)
            Text(proc.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            ValueLabel(value)
        }
        .foregroundStyle(isSelf ? Theme.selfRed : Color.primary)
        .hoverHighlight()
        .help("\(proc.name) (pid \(proc.pid))")
    }
}

// MARK: - Copyable value

struct CopyValue: View {
    var text: String
    @LocalState private var copied = false
    @LocalState private var hovering = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.snappy) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { withAnimation(.snappy) { copied = false } }
        } label: {
            HStack(spacing: 4) {
                if copied {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.good)
                    Text("Copied").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.good)
                } else {
                    Text(text).font(.system(size: 12.5).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75).truncationMode(.middle)
                        .underline(hovering, color: .secondary)
                    if hovering { Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy")
    }
}

struct CopyRow: View {
    var label: String
    var value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            CopyValue(text: value)
        }
        .hoverHighlight()
    }
}

// MARK: - Footer

@MainActor enum AppIcons {
    private static var cache: [String: CGImage] = [:]
    static func icon(bundleID: String) -> CGImage? {
        if let i = cache[bundleID] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache[bundleID] = cg
        return cg
    }
}

private struct FooterIcon: View {
    @Environment(\.isSnapshot) private var snapshot
    var bundleID: String? = nil
    var symbol: String
    var help: String
    var action: () -> Void
    @LocalState private var hovering = false
    var body: some View {
        Button(action: action) {
            Group {
                if !snapshot, let id = bundleID, let cg = AppIcons.icon(bundleID: id) {
                    Canvas { ctx, size in ctx.draw(Image(decorative: cg, scale: 2), in: CGRect(origin: .zero, size: size)) }
                } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Bottom card: app shortcuts, settings, quit.
struct PanelFooter: View {
    var body: some View {
        Card(vPad: 7) {
            HStack(spacing: 0) {
                FooterIcon(bundleID: "com.apple.ActivityMonitor", symbol: "waveform.path.ecg", help: "Activity Monitor") { PanelActions.open(bundleID: "com.apple.ActivityMonitor") }
                Spacer(minLength: 0)
                FooterIcon(bundleID: "com.apple.Console", symbol: "text.alignleft", help: "Console") { PanelActions.open(bundleID: "com.apple.Console") }
                Spacer(minLength: 0)
                FooterIcon(bundleID: "com.apple.Terminal", symbol: "terminal", help: "Terminal") { PanelActions.open(bundleID: "com.apple.Terminal") }
                Spacer(minLength: 0)
                FooterIcon(bundleID: "com.apple.SystemProfiler", symbol: "info.circle", help: "System Information") { PanelActions.open(bundleID: "com.apple.SystemProfiler") }
                Spacer(minLength: 0)
                FooterIcon(symbol: "gearshape", help: "Settings…") { PanelActions.openSettings() }
                Spacer(minLength: 0)
                FooterIcon(symbol: "power", help: "Quit XDRStat") { NSApp.terminate(nil) }
            }
        }
    }
}
