// SMC / IOKit sensors sampler. Call from a single serial queue.
import Foundation

final class SensorsSampler {
    private let smc: SMCClient?
    private let tables: SensorCatalog.Tables
    private let battery = BatteryReader()
    private let hid: HIDTemperatures?
    private let pstrKey = SMCClient.code("PSTR")

    // Per-group scratch to avoid re-deriving structure every tick.
    private let groups = SensorGroup.allCases
    private let groupIndex: [SensorGroup: Int]

    init() {
        groupIndex = Dictionary(uniqueKeysWithValues: SensorGroup.allCases.enumerated().map { ($1, $0) })
        if let s = SMCClient() {
            smc = s
            tables = SensorCatalog.build(smc: s)
            hid = nil
        } else {
            smc = nil
            tables = SensorCatalog.Tables()
            hid = HIDTemperatures()
        }
    }

    /// `detailed`: the Sensors panel is open, read everything. Otherwise only what the menu bar needs:
    /// the headline dies, System Total, and any `pinned` sensor IDs.
    func sample(detailed: Bool, pinned: Set<String> = []) -> SensorsSnapshot {
        var snap = SensorsSnapshot()
        // The battery card and the battery/adapter power rows only show in the panel, or when pinned.
        let wantBattery = detailed || pinned.contains("battery.power") || pinned.contains("adapter.power")
        let bat = wantBattery ? battery.read() : BatteryReader.Result()
        snap.battery = bat.battery

        guard let smc else {
            if let hid {
                let r = hid.read()
                snap.temperatures = r.sensors
                snap.cpuTemperature = r.cpuAverage
                if snap.battery.temperatureC == nil {
                    snap.battery.temperatureC = r.sensors.first { $0.group == .battery }?.value
                }
            }
            appendBatteryPower(&snap, bat)
            return snap
        }

        // --- Temperatures
        var byGroup = [[Sensor]](repeating: [], count: groups.count)
        var cpu: [Double] = [], gpu: [Double] = [], mem: [Double] = []
        // Headline GPU temp uses only the dies read on every tick, so its graph doesn't step when the
        // Sensors panel opens (detailed mode reads all dies; the summaries below still use all of them).
        var gpuHeadline: [Double] = []
        var batteryTemps: [Double] = []
        // A pinned group summary ("GPU Hottest", "Memory Average") needs every die of that group.
        let allGPU = detailed || pinned.contains("gpu.avg") || pinned.contains("gpu.max")
        let allMem = detailed || pinned.contains("memory.avg") || pinned.contains("memory.max")
        for d in tables.temps {
            let wanted = d.essential || pinned.contains(d.id) || (d.role == .gpuDie ? allGPU : d.role == .memDie ? allMem : detailed)
            guard wanted, let v = smc.readValue(d.key), SensorCatalog.validTemp(v) else { continue }
            switch d.role {
            case .cpuDie: cpu.append(v)
            case .gpuDie: gpu.append(v); if d.essential { gpuHeadline.append(v) }
            case .memDie: mem.append(v)
            case .plain: break
            }
            if d.group == .battery { batteryTemps.append(v) }
            byGroup[groupIndex[d.group] ?? 0].append(Sensor(id: d.id, name: d.name, group: d.group, value: v, unit: .celsius))
        }
        func summaries(_ g: SensorGroup, _ prefix: String, _ label: String, _ vals: [Double]) {
            guard !vals.isEmpty, let mx = vals.max() else { return }
            let avg = vals.reduce(0, +) / Double(vals.count)
            let i = groupIndex[g] ?? 0
            byGroup[i].insert(Sensor(id: "\(prefix).avg", name: "\(label) Average", group: g, value: avg, unit: .celsius), at: 0)
            byGroup[i].insert(Sensor(id: "\(prefix).max", name: "\(label) Hottest", group: g, value: mx, unit: .celsius), at: 1)
        }
        summaries(.cpu, "cpu", "CPU", cpu)
        summaries(.gpu, "gpu", "GPU", gpu)
        summaries(.memory, "memory", "Memory", mem)
        snap.temperatures = byGroup.flatMap { $0 }

        // Headline choice: plain average over every CPU die (Ts* super + Tp* performance).
        // Averaging avoids a single spiky die dominating the menu bar; the hottest die is
        // available as the "cpu.max" sensor.
        if !cpu.isEmpty { snap.cpuTemperature = cpu.reduce(0, +) / Double(cpu.count) }
        if !gpuHeadline.isEmpty { snap.gpuTemperature = gpuHeadline.reduce(0, +) / Double(gpuHeadline.count) }

        // Battery temperature fallback (registry exposes none on this machine).
        if wantBattery, snap.battery.temperatureC == nil {
            if let v = smc.readValue("TB0T"), SensorCatalog.validTemp(v) {
                snap.battery.temperatureC = v
            } else if !batteryTemps.isEmpty {
                snap.battery.temperatureC = batteryTemps.reduce(0, +) / Double(batteryTemps.count)
            }
        }

        // --- Fans (only the panel shows them)
        for f in tables.fans where detailed {
            guard let ac = smc.readValue(f.ac), ac.isFinite, ac >= 0 else { continue }
            let mn = smc.readValue(f.mn) ?? 0
            let mx = smc.readValue(f.mx) ?? max(ac, mn)
            let tg = smc.readValue(f.tg)
            snap.fans.append(FanSample(id: f.index, name: f.name, rpm: ac, minRPM: mn, maxRPM: mx, targetRPM: tg))
        }

        // --- Power / voltage / current
        for d in tables.power where detailed || d.essential || pinned.contains(d.id) {
            guard let v = smc.readValue(d.key), SensorCatalog.validValue(v, unit: .watts) else { continue }
            snap.power.append(Sensor(id: d.id, name: d.name, group: d.group, value: v, unit: .watts))
            if d.key == pstrKey { snap.systemPowerW = v }
        }
        appendBatteryPower(&snap, bat)
        for d in tables.volts where detailed || d.essential || pinned.contains(d.id) {
            guard let v = smc.readValue(d.key), SensorCatalog.validValue(v, unit: .volts) else { continue }
            snap.voltages.append(Sensor(id: d.id, name: d.name, group: d.group, value: v, unit: .volts))
        }
        for d in tables.amps where detailed || d.essential || pinned.contains(d.id) {
            guard let v = smc.readValue(d.key), SensorCatalog.validValue(v, unit: .amps) else { continue }
            snap.currents.append(Sensor(id: d.id, name: d.name, group: d.group, value: v, unit: .amps))
        }
        return snap
    }

    /// Battery / adapter power computed from IOKit, placed after the named SMC rails.
    private func appendBatteryPower(_ snap: inout SensorsSnapshot, _ bat: BatteryReader.Result) {
        let b = bat.battery
        guard b.present, b.voltageV > 0 else { return }
        // Insert after essential (named) entries so "System Total" stays first.
        var extra: [Sensor] = [Sensor(id: "battery.power", name: "Battery (signed)", group: .battery, value: b.powerW, unit: .watts)]
        if let a = bat.adapterInputW {
            extra.append(Sensor(id: "adapter.power", name: "Adapter In", group: .power, value: a, unit: .watts))
        }
        let pos = snap.power.firstIndex { $0.name.hasPrefix("Rail ") } ?? snap.power.count
        snap.power.insert(contentsOf: extra, at: pos)
    }
}
