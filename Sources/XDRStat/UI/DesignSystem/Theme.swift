import SwiftUI
import AppKit

enum Theme {
    static let panelWidth: CGFloat = 320
    static let pad: CGFloat = 8     // outer padding and gap between cards
    /// Liquid Glass shapes are concentric: a card's corner radius is the panel's minus the padding between them.
    static let panelCornerRadius: CGFloat = 20
    static let cardCornerRadius: CGFloat = panelCornerRadius - pad

    static let user = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let system = Color(red: 1.0, green: 0.36, blue: 0.34)
    static let gpu = Color(red: 0.70, green: 0.42, blue: 0.96)
    static let superCore = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let perfCore = Color(red: 0.22, green: 0.76, blue: 0.70)
    static let down = Color(red: 0.20, green: 0.74, blue: 0.48)
    static let up = Color(red: 1.0, green: 0.55, blue: 0.20)
    static let good = Color(red: 0.20, green: 0.78, blue: 0.40)
    static let warn = Color(red: 1.0, green: 0.78, blue: 0.18)
    static let bad = Color(red: 1.0, green: 0.30, blue: 0.28)
    static let accent = Color(red: 0.25, green: 0.52, blue: 1.0)
    /// Coloured text and glyphs use system colours, not the fixed brand RGB used for graph fills: macOS
    /// adapts system colours for legibility on Liquid Glass, where a fixed mid-blue all but disappears.
    static let title = Color.blue
    static let positive = Color.green
    // iStat-style palette
    static let pink = Color(red: 0.93, green: 0.36, blue: 0.62)
    static let amber = Color(red: 0.98, green: 0.78, blue: 0.22)
    static let ringTrack = Color.primary.opacity(0.20)
    /// Cards are the content layer on top of the glass panel: a plate substantial enough that charts and
    /// small text stay legible whatever wallpaper shows through the glass around them.
    static let cardFill = dynamic(light: NSColor.white.withAlphaComponent(0.55), dark: NSColor.black.withAlphaComponent(0.24))
    static let cardStroke = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.10))

    /// A colour that differs between the light and dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static func kind(_ k: CoreKind) -> Color { k == .superCore ? superCore : perfCore }

    static func pressure(_ l: MemoryPressureLevel) -> Color {
        switch l { case .normal: good; case .warning: warn; case .critical: bad }
    }

    /// Cool blue (30°C) → amber (60°C) → red (100°C).
    static func heat(_ c: Double) -> Color {
        let t = max(0, min(1, (c - 30) / 70))
        let blue = (0.30, 0.62, 1.0), amber = (1.0, 0.76, 0.20), red = (1.0, 0.28, 0.25)
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ f: Double) -> Color {
            Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
        }
        return t < 0.45 ? mix(blue, amber, t / 0.45) : mix(amber, red, (t - 0.45) / 0.55)
    }

    static let mono11 = Font.system(size: 11, weight: .regular).monospacedDigit()
    static let mono12 = Font.system(size: 12, weight: .medium).monospacedDigit()
}

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isSnapshot: Bool { get { self[SnapshotKey.self] } set { self[SnapshotKey.self] = newValue } }
}

/// Everything a panel or menu label needs, as a plain value (so panels can be rendered with mock data).
struct MonitorState {
    var chip = ChipSnapshot()
    var memory = MemorySnapshot()
    var network = NetworkSnapshot()
    var sensors = SensorsSnapshot()
    var cpuUserHistory = History(), cpuSystemHistory = History()
    var gpuHistory = History(), memoryPressureHistory = History()
    var netDownHistory = History(), netUpHistory = History()
    var cpuTempHistory = History(), gpuTempHistory = History(), systemPowerHistory = History()
    var pinnedHistory = History()
    var unit: TemperatureUnit = .celsius
    var fetchPublicIP = false
    var pinnedSensorIDs: [String] = []
    var style: MenuBarStyle = .graph

    @MainActor init() {}
    @MainActor init(_ m: SystemMonitor, _ s: AppSettings) {
        chip = m.chip; memory = m.memory; network = m.network; sensors = m.sensors
        cpuUserHistory = m.cpuUserHistory; cpuSystemHistory = m.cpuSystemHistory
        gpuHistory = m.gpuHistory; memoryPressureHistory = m.memoryPressureHistory
        netDownHistory = m.netDownHistory; netUpHistory = m.netUpHistory
        cpuTempHistory = m.cpuTempHistory; gpuTempHistory = m.gpuTempHistory; systemPowerHistory = m.systemPowerHistory
        pinnedHistory = m.pinnedHistory
        unit = s.temperatureUnit; fetchPublicIP = s.fetchPublicIP
        pinnedSensorIDs = s.menuBarSensorIDs; style = s.menuBarStyle
    }
}

// The CommandLineTools toolchain lacks the SwiftUIMacros plugin, so `@State` (a macro in the
// macOS 27 SDK) can't be expanded. A typealias resolves to the plain property wrapper instead.
typealias LocalState<T> = SwiftUI.State<T>

/// Site screenshots: draw real app icons even in snapshot renders (set by SnapshotRunner.marketing).
@MainActor enum SnapshotOptions { static var realIcons = false }
