import SwiftUI
import AppKit

/// Renders a compact SwiftUI view to a template NSImage (adapts to light/dark/highlighted menu bars).
@MainActor enum MenuBarRender {
    static func image<V: View>(_ view: V, template: Bool = true) -> NSImage {
        let r = ImageRenderer(content: view.frame(height: 18).foregroundStyle(.black).environment(\.colorScheme, .light))
        r.scale = 2
        let img = r.nsImage ?? NSImage(size: NSSize(width: 1, height: 18))
        img.isTemplate = template
        return img
    }
}


private let valueFont = Font.system(size: 12.5, weight: .medium).monospacedDigit()

// MARK: - CPU

struct CPUMenuLabelContent: View {
    var state: MonitorState
    var body: some View {
        let cpu = state.chip.cpu
        let pct = Text(String(format: "%.0f%%", cpu.usage * 100)).font(valueFont).frame(width: 36, alignment: .trailing)
        switch state.style {
        case .graph:
            HStack(spacing: 4) {
                HStack(alignment: .bottom, spacing: 1.5) {
                    let bars = cpu.clusters.isEmpty ? [cpu.usage] : cpu.clusters.map(\.usage)
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, u in MiniBar(value: u) }
                }
                pct
            }
        case .text: pct
        case .compact:
            HStack(spacing: 3) { Image(systemName: "cpu").font(.system(size: 12, weight: .medium)); pct }
        }
    }
}

struct MiniBar: View {
    var value: Double
    var width: CGFloat = 4.5
    var height: CGFloat = 14
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.2).fill(.black.opacity(0.28))
            RoundedRectangle(cornerRadius: 1.2).fill(.black).frame(height: max(1.5, height * CGFloat(min(1, max(0, value)))))
        }.frame(width: width, height: height)
    }
}


// MARK: - Memory

struct MemoryMenuLabelContent: View {
    var state: MonitorState
    var body: some View {
        let m = state.memory
        let pct = Text(String(format: "%.0f%%", m.usedFraction * 100)).font(valueFont).frame(width: 36, alignment: .trailing)
        switch state.style {
        case .graph:
            HStack(spacing: 4) { MiniBar(value: m.pressure, width: 5); pct }
        case .text: pct
        case .compact:
            HStack(spacing: 3) { Image(systemName: "memorychip").font(.system(size: 12, weight: .medium)); pct }
        }
    }
}


// MARK: - Network

enum NetFmt {
    /// Compact fixed-width-friendly rate, e.g. "12.3 KB/s".
    static func short(_ bps: Double) -> String { Fmt.rate(bps) }
}

struct NetworkMenuLabelContent: View {
    var state: MonitorState
    var body: some View {
        let n = state.network
        let lines = VStack(alignment: .trailing, spacing: 0) {
            Text("↑ " + NetFmt.short(n.upBytesPerSec))
            Text("↓ " + NetFmt.short(n.downBytesPerSec))
        }
        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
        .frame(width: 66, alignment: .trailing)
        switch state.style {
        case .graph:
            HStack(spacing: 4) {
                MirroredGraph(down: Array(state.netDownHistory.values.suffix(30)), up: Array(state.netUpHistory.values.suffix(30)),
                              scale: Fmt.niceMax(max(state.netDownHistory.max, state.netUpHistory.max, 250_000)),
                              downColor: .black, upColor: .black, capacity: 30)
                    .frame(width: 26, height: 14)
                lines
            }
        case .text: lines
        case .compact:
            HStack(spacing: 3) { Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .medium)); lines }
        }
    }
}


// MARK: - Sensors

struct SensorsMenuLabelContent: View {
    var state: MonitorState
    static func values(_ st: MonitorState) -> [String] {
        let s = st.sensors
        let all = s.temperatures + s.power + s.voltages + s.currents
        let pinned = st.pinnedSensorIDs.compactMap { id in all.first { $0.id == id } }
        if !pinned.isEmpty {
            return pinned.prefix(4).map { x in x.unit == .celsius ? Fmt.temp(x.value, st.unit) : Fmt.sensor(x, unit: st.unit).replacingOccurrences(of: " ", with: "") }
        }
        return [s.cpuTemperature.map { Fmt.temp($0, st.unit) } ?? "--°"]
    }
    var body: some View {
        let vals = Self.values(state)
        let text = Text(vals.joined(separator: " ")).font(valueFont)
        switch state.style {
        case .graph:
            HStack(spacing: 4) {
                Sparkline(values: Array(state.cpuTempHistory.values.suffix(30)), color: .black, capacity: 30)
                    .frame(width: 24, height: 13)
                text
            }
        case .text: text
        case .compact:
            HStack(spacing: 2) { Image(systemName: "thermometer.medium").font(.system(size: 12, weight: .medium)); text }
        }
    }
}

