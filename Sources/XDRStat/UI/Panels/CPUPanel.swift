import SwiftUI

struct CPUPanel: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        CPUPanelContent(state: MonitorState(monitor, settings))
            .onAppear { monitor.detail.cpu = true }
            .onDisappear { monitor.detail.cpu = false }
    }
}

struct CPUPanelContent: View {
    var state: MonitorState
    private var cpu: CPUSnapshot { state.chip.cpu }
    private var gpu: GPUSnapshot { state.chip.gpu }

    var body: some View {
        PanelFrame {
            header
            if !cpu.cores.isEmpty { cores }
            processes
            if !cpu.clusters.isEmpty { clusters }
            gpuCard
            powerCard
            loadCard
            uptimeCard
            PanelFooter()
        }
    }

    // MARK: header

    private var headerFreq: (String, String)? {
        cpu.clusters.compactMap(\.frequencyMHz).max().map { Fmt.freqParts($0) }
    }

    private var historyScale: Double {
        let peak = zip(state.cpuUserHistory.values.suffix(120), state.cpuSystemHistory.values.suffix(120)).map { $0 + $1 }.max() ?? 0
        return min(1, max(0.25, (peak * 4).rounded(.up) / 4))
    }

    private var header: some View {
        Card(spacing: 8) {
            CardTitle(title: "CPU") {
                if let f = headerFreq { ValueLabel(f, size: 13, weight: .medium) }
            }
            BarHistory(layers: [state.cpuUserHistory.values, state.cpuSystemHistory.values],
                       colors: [Theme.accent, Theme.pink], maxValue: historyScale)
                .frame(height: 62)
            HStack(spacing: 22) {
                LegendRow(color: Theme.accent, name: "User", value: ValueLabel(value: String(format: "%.0f", cpu.user * 100), unit: "%", size: 13, weight: .medium), nameColor: .primary)
                LegendRow(color: Theme.pink, name: "System", value: ValueLabel(value: String(format: "%.0f", cpu.system * 100), unit: "%", size: 13, weight: .medium), nameColor: .primary)
            }
        }
    }

    // MARK: cores

    private func kindAverage(_ k: CoreKind) -> Double? {
        let c = cpu.cores.filter { $0.kind == k }
        return c.isEmpty ? nil : c.map(\.usage).reduce(0, +) / Double(c.count)
    }

    private var cores: some View {
        let ordered = cpu.cores.filter { $0.kind == .performance }.sorted { $0.id < $1.id } +
                      cpu.cores.filter { $0.kind == .superCore }.sorted { $0.id < $1.id }
        let perRow = 9
        let rows = stride(from: 0, to: ordered.count, by: perRow).map { Array(ordered[$0..<min($0 + perRow, ordered.count)]) }
        return Card(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        ForEach(0..<perRow, id: \.self) { i in
                            if i < row.count { CoreRing(core: row[i]) } else { Color.clear.aspectRatio(1, contentMode: .fit) }
                        }
                    }
                }
            }
            .padding(.bottom, 2)
            if let p = kindAverage(.performance) {
                LegendRow(color: Theme.pink, name: "Performance Cores", value: ValueLabel(value: String(format: "%.0f", p * 100), unit: "%", size: 13, weight: .medium), nameColor: .secondary)
            }
            if let s = kindAverage(.superCore) {
                LegendRow(color: Theme.accent, name: "Super Cores", value: ValueLabel(value: String(format: "%.0f", s * 100), unit: "%", size: 13, weight: .medium), nameColor: .secondary)
            }
        }
    }

    // MARK: processes

    private var processes: some View {
        Card(spacing: 5) {
            CardTitle("CPU Processes")
            if cpu.topProcesses.isEmpty {
                EmptyHint(text: "Collecting process data…")
            } else {
                ForEach(cpu.topProcesses.prefix(5)) { p in
                    ProcessRow(proc: p, value: (String(format: "%.1f", p.cpuPercent), "%"))
                }
            }
        }
    }

    // MARK: clusters

    private var clusters: some View {
        Card(spacing: 5) {
            CardTitle(title: "Clusters") { if let w = cpu.powerW { ValueLabel(Fmt.wattsParts(w), size: 13, weight: .medium) } }
            ForEach(cpu.clusters) { c in
                HStack(spacing: 7) {
                    Circle().fill(c.kind == .superCore ? Theme.accent : Theme.pink).frame(width: 9, height: 9)
                    Text(c.name.replacingOccurrences(of: "Performance", with: "Perf")).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    ValueLabel(value: String(format: "%.0f", c.usage * 100), unit: "%").frame(width: 42, alignment: .trailing)
                    Group {
                        if let f = c.frequencyMHz { ValueLabel(Fmt.freqParts(f)) } else { Text("—") }
                    }.frame(width: 70, alignment: .trailing)
                    Group {
                        if let w = c.powerW { ValueLabel(Fmt.wattsParts(w)) } else { Text("—") }
                    }.frame(width: 56, alignment: .trailing)
                }
                .hoverHighlight()
            }
        }
    }

    // MARK: GPU

    private var gpuMemFraction: Double {
        let total = state.memory.total > 0 ? state.memory.total : gpu.memoryAllocatedBytes
        return total > 0 ? Double(gpu.memoryInUseBytes) / Double(total) : 0
    }

    private var gpuCard: some View {
        let temp = state.sensors.gpuTemperature
        let tempShown = temp.map { state.unit == .celsius ? $0 : $0 * 9 / 5 + 32 }
        let ghz = gpu.frequencyMHz.map { $0 / 1000 }
        return Card(spacing: 8) {
            CardTitle(title: "GPU") {
                if gpu.coreCount > 0 { ValueLabel(value: "\(gpu.coreCount)", unit: "cores", size: 13, weight: .medium) }
            }
            BarHistory(layers: [state.gpuHistory.values], colors: [Theme.accent], maxValue: 1).frame(height: 30)
            HStack(spacing: 8) {
                GaugeRing(fraction: gpu.utilization, color: Theme.accent, value: String(format: "%.0f", gpu.utilization * 100), unit: "%", caption: "GPU")
                GaugeRing(fraction: gpuMemFraction, color: Theme.accent, value: String(format: "%.0f", gpuMemFraction * 100), unit: "%", caption: "MEM")
                GaugeRing(fraction: (temp ?? 0) / 100, color: (temp ?? 0) >= 85 ? Theme.bad : (temp ?? 0) >= 70 ? Theme.amber : Theme.accent,
                          value: tempShown.map { String(format: "%.0f", $0) } ?? "—", unit: "°", caption: "TMP")
                GaugeRing(fraction: gpu.maxFrequencyMHz.map { ($0 > 0 ? (gpu.frequencyMHz ?? 0) / $0 : 0) } ?? 0, color: Theme.accent,
                          value: ghz.map { String(format: "%.2f", $0) } ?? "—", unit: "", caption: "GHZ")
            }
            // Explicit height: aspect-ratio rings alone collapse when a host asks for the minimum fitting size.
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            VStack(spacing: 3) {
                LegendRow(color: nil, name: "Renderer", value: ValueLabel(value: String(format: "%.0f", gpu.rendererUtilization * 100), unit: "%"))
                LegendRow(color: nil, name: "Tiler", value: ValueLabel(value: String(format: "%.0f", gpu.tilerUtilization * 100), unit: "%"))
                if let w = gpu.powerW { LegendRow(color: nil, name: "Power", value: ValueLabel(Fmt.wattsParts(w))) }
                if gpu.memoryInUseBytes > 0 {
                    LegendRow(color: nil, name: "Memory", value: ValueLabel(Fmt.bytesParts(gpu.memoryInUseBytes)))
                }
            }
        }
    }

    // MARK: power

    private static let compColors: [Color] = [
        Color(red: 0.35, green: 0.80, blue: 0.95), Color(red: 0.55, green: 0.85, blue: 0.45),
        Color(red: 0.95, green: 0.80, blue: 0.30), Color(red: 0.70, green: 0.55, blue: 0.95), Color(red: 0.60, green: 0.60, blue: 0.70)]

    private var powerSegments: [Segment] {
        var segs: [Segment] = []
        if let c = cpu.powerW { segs.append(Segment(id: "CPU", value: c, color: Theme.accent)) }
        if let g = gpu.powerW { segs.append(Segment(id: "GPU", value: g, color: Theme.pink)) }
        let comps = state.chip.components.filter { $0.watts > 0 }.sorted { $0.watts > $1.watts }
        for (i, c) in comps.prefix(4).enumerated() {
            segs.append(Segment(id: c.name, value: c.watts, color: Self.compColors[i % Self.compColors.count]))
        }
        let rest = comps.dropFirst(4).map(\.watts).reduce(0, +)
        if rest > 0 { segs.append(Segment(id: "Other", value: rest, color: Self.compColors[4])) }
        return segs
    }

    @ViewBuilder private var powerCard: some View {
        let segs = powerSegments
        if !segs.isEmpty {
            Card(spacing: 8) {
                CardTitle(title: "SoC Power") { ValueLabel(Fmt.wattsParts(segs.map(\.value).reduce(0, +)), size: 13, weight: .medium) }
                StackedBar(segments: segs, height: 8)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 3) {
                    ForEach(segs) { s in LegendRow(color: s.color, name: s.id, value: ValueLabel(Fmt.wattsParts(s.value))) }
                }
            }
        }
    }

    // MARK: load / uptime

    private var loadCard: some View {
        Card(spacing: 4) {
            CardTitle(title: "Load") {
                Text(cpu.loadAverage.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  "))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
            }
            if cpu.processCount > 0 {
                HStack {
                    Text("\(cpu.processCount) processes · \(cpu.threadCount) threads").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var uptimeCard: some View {
        Card(spacing: 0) {
            CardTitle(title: "Uptime") {
                Text(cpu.uptime > 0 ? Fmt.uptimeLong(cpu.uptime) : "—").font(.system(size: 13, weight: .medium).monospacedDigit())
            }
        }
    }
}

/// One core as a ring: fill = usage, pink for performance cores, blue for super cores.
struct CoreRing: View {
    var core: CoreSample
    var body: some View {
        SegmentRing(segments: [(core.usage, core.kind == .superCore ? Theme.accent : Theme.pink)], lineWidth: 3.5)
            .aspectRatio(1, contentMode: .fit)
            .help("Core \(core.id) · \(core.kind.displayName)\n\(Fmt.percent(core.usage)) (user \(Fmt.percent(core.user)), system \(Fmt.percent(core.system)))" +
                  (core.frequencyMHz.map { "\n~\(Fmt.freq($0))" } ?? "") + (core.powerW.map { "\n\(Fmt.watts($0))" } ?? ""))
    }
}
