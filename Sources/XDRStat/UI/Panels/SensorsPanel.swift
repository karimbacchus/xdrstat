import SwiftUI

struct SensorsPanel: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        SensorsPanelContent(state: MonitorState(monitor, settings), onTogglePin: { id in
            if let i = settings.menuBarSensorIDs.firstIndex(of: id) { settings.menuBarSensorIDs.remove(at: i) }
            else { settings.menuBarSensorIDs.append(id) }
        })
        .onAppear { monitor.detail.sensors = true }
        .onDisappear { monitor.detail.sensors = false }
    }
}

struct SensorsPanelContent: View {
    var state: MonitorState
    var onTogglePin: (String) -> Void = { _ in }
    init(state: MonitorState, onTogglePin: @escaping (String) -> Void = { _ in }, initiallyExpanded: Set<String> = []) {
        self.state = state; self.onTogglePin = onTogglePin
        _expanded = LocalState(initialValue: initiallyExpanded)
    }
    @LocalState private var expanded: Set<String>
    @LocalState private var query = ""
    @Environment(\.isSnapshot) private var snapshot

    private var s: SensorsSnapshot { state.sensors }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        PanelFrame(maxHeight: 600) {
            summary
            search
            if !s.fans.isEmpty && !searching { fans }
            if s.battery.present && !searching { battery }
            temperatures
            extraSection("Power", s.power)
            extraSection("Voltage", s.voltages)
            extraSection("Current", s.currents)
            PanelFooter()
        }
    }

    // MARK: summary tiles

    private var summary: some View {
        let u = state.unit
        let fanMax = s.fans.map(\.rpm).max()
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.pad), GridItem(.flexible())], spacing: Theme.pad) {
            tile("CPU", s.cpuTemperature.map { Fmt.temp($0, u, suffix: true) }, state.cpuTempHistory.values, s.cpuTemperature.map(Theme.heat) ?? .secondary)
            tile("GPU", s.gpuTemperature.map { Fmt.temp($0, u, suffix: true) }, state.gpuTempHistory.values, s.gpuTemperature.map(Theme.heat) ?? .secondary)
            tile("System Power", s.systemPowerW.map { Fmt.watts($0) }, state.systemPowerHistory.values, Theme.accent)
            fanTile(fanMax)
        }
    }

    private func tile(_ title: String, _ value: String?, _ history: [Double], _ color: Color) -> some View {
        Card(spacing: 4, vPad: 9) {
            Text(title.uppercased()).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
            Text(value ?? "—").font(.system(size: 20, weight: .medium)).monospacedDigit()
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(values: history, color: color).frame(height: 22)
        }
    }

    private func fanTile(_ rpm: Double?) -> some View {
        Card(spacing: 4, vPad: 9) {
            Text("FANS").font(.system(size: 11.5)).foregroundStyle(Theme.accent)
            Text(rpm.map { Fmt.rpm($0) } ?? "—").font(.system(size: 20, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            VStack(spacing: 4) {
                ForEach(s.fans.prefix(2)) { f in BarMeter(value: f.fraction, color: Theme.accent, height: 5) }
                if s.fans.isEmpty { BarMeter(value: 0, color: Theme.accent, height: 5) }
            }.frame(height: 22, alignment: .center)
        }
    }

    private var search: some View {
        Card(vPad: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                if snapshot { Text("Filter sensors").font(.system(size: 12.5)).foregroundStyle(.tertiary); Spacer() }
                else { TextField("Filter sensors", text: $query).textFieldStyle(.plain).font(.system(size: 12.5)) }
                if searching {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: fans

    private var fans: some View {
        Card(spacing: 8) {
            CardTitle("Fans")
            ForEach(s.fans) { f in
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "fan").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(f.name).font(.system(size: 12.5))
                        Spacer()
                        ValueLabel(value: f.rpm < 1 ? "Off" : Fmt.rpm(f.rpm).replacingOccurrences(of: " rpm", with: ""), unit: f.rpm < 1 ? "" : "rpm")
                    }
                    BarMeter(value: f.fraction, color: Theme.accent, height: 5)
                    HStack {
                        Text(Fmt.rpm(f.minRPM).replacingOccurrences(of: " rpm", with: ""))
                        Spacer()
                        Text(Fmt.rpm(f.maxRPM).replacingOccurrences(of: " rpm", with: ""))
                    }.font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                }
                .hoverHighlight()
            }
        }
    }

    // MARK: battery

    private var battery: some View {
        let b = s.battery
        let stateText = b.isCharging ? "Charging" : b.isFullyCharged ? "Fully charged" : b.isPluggedIn ? "Plugged in" : "On battery"
        let col: Color = b.percent < 0.2 && !b.isPluggedIn ? Theme.bad : b.isCharging ? Theme.good : Theme.accent
        return Card(spacing: 8) {
            CardTitle(title: "Battery") { Text(stateText).font(.system(size: 12.5)).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                ValueLabel(value: String(format: "%.0f", b.percent * 100), unit: "%", size: 22, weight: .medium)
                    .frame(width: 66, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    BarMeter(value: b.percent, color: col, height: 8)
                    Text(b.minutesRemaining.map { "\(Fmt.minutes($0)) \(b.isCharging ? "until full" : "remaining")" } ?? (b.isPluggedIn ? "On power adapter" : "Calculating…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 3) {
                ForEach(Array(batteryItems(b).enumerated()), id: \.offset) { _, it in InfoRow(label: it.0, value: it.1) }
            }
        }
    }

    private func batteryItems(_ b: BatterySnapshot) -> [(String, String)] {
        var items: [(String, String)] = [
            ("Health", b.healthFraction.map { Fmt.percent($0) } ?? "—"),
            ("Cycles", "\(b.cycleCount)"),
            ("Temperature", b.temperatureC.map { Fmt.temp($0, state.unit, suffix: true) } ?? "—"),
            (b.powerW < 0 ? "Power out" : "Power in", Fmt.watts(abs(b.powerW))),
        ]
        if let a = b.adapterWatts { items.append(("Adapter", "\(a) W" + (b.adapterName.map { " · \($0)" } ?? ""))) }
        return items
    }

    // MARK: temperatures

    private struct Group: Identifiable { var group: SensorGroup; var sensors: [Sensor]; var avg: Sensor?; var max: Sensor?; var id: String { group.id } }

    private func matches(_ x: Sensor) -> Bool {
        !searching || x.name.localizedCaseInsensitiveContains(query) || x.group.rawValue.localizedCaseInsensitiveContains(query)
    }

    private var groups: [Group] {
        let by = Dictionary(grouping: s.temperatures, by: \.group)
        return SensorGroup.allCases.compactMap { g in
            guard let all = by[g] else { return nil }
            let avg = all.first { $0.id.hasSuffix(".avg") }, mx = all.first { $0.id.hasSuffix(".max") }
            let real = all.filter { !$0.id.hasSuffix(".avg") && !$0.id.hasSuffix(".max") }.filter(matches)
            if searching && real.isEmpty { return nil }
            return Group(group: g, sensors: real.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, avg: avg, max: mx)
        }
    }

    @ViewBuilder private var temperatures: some View {
        let gs = groups
        if gs.isEmpty {
            Card(spacing: 6) {
                CardTitle("Temperatures")
                EmptyHint(text: searching ? "No sensors match “\(query)”" : "Reading sensors…")
            }
        } else {
            Card(spacing: 2, vPad: 8) {
                CardTitle(title: "Temperatures") { Text("\(s.temperatures.count) sensors").font(.system(size: 11.5)).foregroundStyle(.secondary) }.padding(.bottom, 4)
                ForEach(gs) { g in
                    let key = "T-" + g.id
                    let open = searching || expanded.contains(key)
                    let avg = g.avg?.value ?? average(g.sensors), mx = g.max?.value ?? g.sensors.map(\.value).max()
                    DisclosureRow(title: g.group.rawValue, count: g.sensors.count, isOpen: open, summary: {
                        HStack(spacing: 8) {
                            if let avg { Text("avg \(Fmt.temp(avg, state.unit))").foregroundStyle(.secondary) }
                            if let mx {
                                HStack(spacing: 3) { Circle().fill(Theme.heat(mx)).frame(width: 6, height: 6); Text("max \(Fmt.temp(mx, state.unit))") }
                            }
                        }.font(Theme.mono11)
                    }, toggle: { toggle(key) }) {
                        ForEach(g.sensors) { x in SensorRow(sensor: x, unit: state.unit, pinned: state.pinnedSensorIDs.contains(x.id), onPin: { onTogglePin(x.id) }) }
                    }
                }
            }
        }
    }

    private func average(_ a: [Sensor]) -> Double? { a.isEmpty ? nil : a.map(\.value).reduce(0, +) / Double(a.count) }

    private func toggle(_ key: String) {
        withAnimation(.snappy(duration: 0.28)) { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } }
    }

    @ViewBuilder private func extraSection(_ title: String, _ list: [Sensor]) -> some View {
        let shown = list.filter(matches)
        if !shown.isEmpty {
            let key = "X-" + title
            Card(spacing: 0, vPad: 5, hPad: 8) {
                DisclosureRow(title: title, count: shown.count, isOpen: searching || expanded.contains(key), isSection: true, summary: { EmptyView() }, toggle: { toggle(key) }) {
                    ForEach(shown) { x in SensorRow(sensor: x, unit: state.unit, pinned: state.pinnedSensorIDs.contains(x.id), onPin: { onTogglePin(x.id) }) }
                }
            }
        }
    }
}

struct DisclosureRow<Summary: View, Content: View>: View {
    var title: String
    var count: Int
    var isOpen: Bool
    var isSection = false
    @ViewBuilder var summary: Summary
    var toggle: () -> Void
    @ViewBuilder var content: Content
    @LocalState private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10)
                    if isSection {
                        Text(title.uppercased()).font(.system(size: 13)).foregroundStyle(Theme.accent)
                    } else {
                        Text(title).font(.system(size: 12.5))
                    }
                    Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if !isOpen { summary }
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if isOpen {
                VStack(spacing: 0) { content }
                    .padding(.leading, 8).padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

struct SensorRow: View {
    var sensor: Sensor
    var unit: TemperatureUnit
    var pinned: Bool
    var onPin: () -> Void
    @LocalState private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPin) {
                Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 9.5))
                    .foregroundStyle(pinned ? Theme.accent : Color.secondary)
                    .opacity(pinned || hovering ? 1 : 0)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(pinned ? "Remove from menu bar" : "Show in menu bar")
            Text(sensor.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if sensor.unit == .celsius {
                BarMeter(value: (sensor.value - 30) / 70, color: Theme.heat(sensor.value), height: 4).frame(width: 34)
            }
            Text(Fmt.sensor(sensor, unit: unit)).font(Theme.mono11).frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(pinned ? "Remove from Menu Bar" : "Show in Menu Bar", action: onPin)
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Fmt.sensor(sensor, unit: unit), forType: .string)
            }
        }
    }
}
