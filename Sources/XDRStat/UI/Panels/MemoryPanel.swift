import SwiftUI

struct MemoryPanel: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        MemoryPanelContent(state: MonitorState(monitor, settings))
            .onAppear { monitor.detail.memory = true }
            .onDisappear { monitor.detail.memory = false }
    }
}

struct MemoryPanelContent: View {
    var state: MonitorState
    private var m: MemorySnapshot { state.memory }

    private static let appC = Theme.accent
    private static let wiredC = Theme.pink
    private static let compC = Theme.amber
    private static let cachedC = Color(red: 0.25, green: 0.76, blue: 0.70)
    private static let freeC = Color.primary.opacity(0.35)

    var body: some View {
        PanelFrame {
            gauges
            legend
            processes
            pagesCard
            swapCard
            PanelFooter()
        }
    }

    private var pressureColor: Color {
        switch m.pressureLevel { case .normal: Theme.accent; case .warning: Theme.amber; case .critical: Theme.bad }
    }

    private func frac(_ b: UInt64) -> Double { m.total > 0 ? Double(b) / Double(m.total) : 0 }

    private var gauges: some View {
        Card(vPad: 14) {
            HStack(spacing: 14) {
                SegmentRing(segments: [(m.pressure, pressureColor)], lineWidth: 6) {
                    VStack(spacing: 0) {
                        ValueLabel(value: String(format: "%.0f", m.pressure * 100), unit: "%", size: 28, weight: .regular)
                        Text("PRESSURE").font(.system(size: 11, weight: .medium))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                SegmentRing(segments: [(frac(m.app), Self.appC), (frac(m.wired), Self.wiredC), (frac(m.compressed), Self.compC)], lineWidth: 6) {
                    VStack(spacing: 0) {
                        ValueLabel(value: String(format: "%.0f", m.usedFraction * 100), unit: "%", size: 28, weight: .regular)
                        Text("MEMORY").font(.system(size: 11, weight: .medium))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private var legend: some View {
        Card(spacing: 3) {
            LegendRow(color: Self.appC, name: "App", value: ValueLabel(Fmt.bytesParts(m.app), size: 13, weight: .medium), nameColor: .primary)
            LegendRow(color: Self.wiredC, name: "Wired", value: ValueLabel(Fmt.bytesParts(m.wired), size: 13, weight: .medium), nameColor: .primary)
            LegendRow(color: Self.compC, name: "Compressed", value: ValueLabel(Fmt.bytesParts(m.compressed), size: 13, weight: .medium), nameColor: .primary)
            LegendRow(color: Self.cachedC, name: "Cached", value: ValueLabel(Fmt.bytesParts(m.cached), size: 13, weight: .medium), nameColor: .primary)
            LegendRow(color: Self.freeC, name: "Free", value: ValueLabel(Fmt.bytesParts(m.free), size: 13, weight: .medium), nameColor: .primary)
        }
    }

    private var processes: some View {
        Card(spacing: 5) {
            CardTitle("Processes")
            if m.topProcesses.isEmpty {
                EmptyHint(text: "Collecting process data…")
            } else {
                ForEach(m.topProcesses.prefix(5)) { p in
                    ProcessRow(proc: p, value: Fmt.bytesParts(p.memoryBytes))
                }
            }
        }
    }

    private var pagesCard: some View {
        Card(spacing: 3) {
            InfoRowPlain(label: "Page Ins", parts: Fmt.rateParts(m.pageInsPerSec * 16384))
            InfoRowPlain(label: "Page Outs", parts: Fmt.rateParts(m.pageOutsPerSec * 16384))
            if let r = m.compressionRatio { InfoRowPlain(label: "Compression", parts: (String(format: "%.1f", r), "×")) }
        }
    }

    private var swapCard: some View {
        Card(spacing: 3) {
            CardTitle(title: "Swap") { ValueLabel(Fmt.bytesParts(m.swapUsed), size: 13, weight: .medium) }
            if m.swapTotal > 0 {
                HStack { Text("of \(Fmt.bytes(m.swapTotal))").font(.system(size: 11.5)).foregroundStyle(.secondary); Spacer() }
            }
        }
    }
}

/// Grey-label row used in the page ins/outs card.
struct InfoRowPlain: View {
    var label: String
    var parts: (String, String)
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ValueLabel(parts, size: 13, weight: .medium)
        }
        .hoverHighlight()
    }
}
