import Foundation

/// Realistic mock data for snapshots / QA (XDRSTAT_SNAPSHOT=/dir).
@MainActor enum MockData {
    private static func series(_ n: Int, base: Double, amp: Double, seed: Double, lo: Double = 0, hi: Double = 1e12) -> [Double] {
        (0..<n).map { i in
            let t = Double(i)
            let v = base + amp * (0.55 * sin(t / 7 + seed) + 0.3 * sin(t / 2.3 + seed * 2) + 0.15 * sin(t * 1.7 + seed * 3))
            return min(hi, max(lo, v))
        }
    }
    private static func hist(_ vals: [Double]) -> History { var h = History(); vals.forEach { h.append($0) }; return h }

    static var state: MonitorState {
        var st = MonitorState()
        // CPU
        var cores: [CoreSample] = []
        let usages: [Double] = [0.62, 0.41, 0.18, 0.55, 0.09, 0.30, 0.34, 0.22, 0.12, 0.07, 0.15, 0.05, 0.28, 0.11, 0.04, 0.02, 0.09, 0.06]
        for i in 0..<18 {
            let k: CoreKind = i < 6 ? .superCore : .performance
            let cl = i < 6 ? 0 : (i < 12 ? 1 : 2)
            cores.append(CoreSample(id: i, kind: k, cluster: cl, user: usages[i] * 0.65, system: usages[i] * 0.35,
                                    frequencyMHz: k == .superCore ? 3400 : 2400, powerW: 0.4))
        }
        func cu(_ r: Range<Int>) -> Double { usages[r].reduce(0, +) / Double(r.count) }
        let clusters = [
            ClusterSample(id: 0, name: "Super", kind: .superCore, usage: cu(0..<6), frequencyMHz: 3820, maxFrequencyMHz: 4608, powerW: 2.31),
            ClusterSample(id: 1, name: "Performance 1", kind: .performance, usage: cu(6..<12), frequencyMHz: 1650, maxFrequencyMHz: 4000, powerW: 0.64),
            ClusterSample(id: 2, name: "Performance 2", kind: .performance, usage: cu(12..<18), frequencyMHz: 912, maxFrequencyMHz: 4000, powerW: 0.21)]
        let procNames: [String] = ["Safari", "WindowServer", "Xcode", "Slack", "kernel_task", "Finder"]
        let procCPU: [Double] = [41.2, 18.7, 12.4, 6.1, 4.8, 1.2]
        var procs: [ProcessUsage] = []
        for i in 0..<procNames.count {
            procs.append(ProcessUsage(pid: Int32(100 + i), name: procNames[i], cpuPercent: procCPU[i], memoryBytes: UInt64(3_400_000_000 / (i + 1))))
        }
        var cpu = CPUSnapshot(cores: cores, clusters: clusters, user: 0.14, system: 0.09, idle: 0.77, powerW: 3.16,
                              loadAverage: [2.41, 2.08, 1.87], uptime: 3 * 86400 + 5 * 3600 + 1260, processCount: 612, threadCount: 3104,
                              topProcesses: procs)
        _ = cpu.usage; cpu.powerW = 3.16
        let gpu = GPUSnapshot(name: "Apple M5 Pro GPU", coreCount: 20, utilization: 0.37, rendererUtilization: 0.34, tilerUtilization: 0.21,
                              frequencyMHz: 1180, maxFrequencyMHz: 1800, powerW: 1.42, memoryInUseBytes: 2_400_000_000, memoryAllocatedBytes: 5_100_000_000)
        st.chip = ChipSnapshot(cpu: cpu, gpu: gpu, components: [PowerComponent(name: "ANE", watts: 0.02), PowerComponent(name: "DRAM", watts: 0.88),
                                                                 PowerComponent(name: "Display", watts: 1.1), PowerComponent(name: "Fabric", watts: 0.35)],
                               chipName: "Apple M5 Pro")
        let n = 120
        st.cpuUserHistory = hist(series(n, base: 0.16, amp: 0.12, seed: 1, lo: 0.01))
        st.cpuSystemHistory = hist(series(n, base: 0.07, amp: 0.05, seed: 2, lo: 0.005))
        st.cpuHistory = hist(zip(st.cpuUserHistory.values, st.cpuSystemHistory.values).map { $0 + $1 })
        st.gpuHistory = hist(series(n, base: 0.35, amp: 0.3, seed: 4, lo: 0.02, hi: 1))
        // Memory
        let gb: UInt64 = 1 << 30
        st.memory = MemorySnapshot(total: 64 * gb, used: UInt64(27.4 * Double(gb)), app: UInt64(17.9 * Double(gb)), wired: UInt64(5.2 * Double(gb)),
                                   compressed: UInt64(4.3 * Double(gb)), cached: 21 * gb, free: UInt64(15.6 * Double(gb)),
                                   pressure: 0.28, pressureLevel: .normal, swapUsed: UInt64(1.2 * Double(gb)), swapTotal: 4 * gb,
                                   pageInsPerSec: 38, pageOutsPerSec: 2, compressionRatio: 2.8,
                                   topProcesses: procs.map { ProcessUsage(pid: $0.pid, name: $0.name, cpuPercent: 0, memoryBytes: $0.memoryBytes) })
        st.memoryPressureHistory = hist(series(n, base: 0.28, amp: 0.1, seed: 5, lo: 0.05, hi: 1))
        st.memoryUsedHistory = hist(series(n, base: 0.43, amp: 0.03, seed: 6, lo: 0.05, hi: 1))
        // Network
        st.network = NetworkSnapshot(
            downBytesPerSec: 3_480_000, upBytesPerSec: 126_000, totalDown: 48_200_000_000, totalUp: 6_900_000_000,
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi‑Fi", kind: .wifi, isPrimary: true, isUp: true, ipv4: ["192.168.1.42"],
                                     ipv6: ["fe80::1c2b:3d4e:5f60:7182", "2a02:8071:1234::42"], macAddress: "a4:83:e7:12:9c:3f", downBytesPerSec: 3_480_000, upBytesPerSec: 126_000),
                NetworkInterfaceInfo(bsdName: "en5", displayName: "Thunderbolt Ethernet", kind: .ethernet, isPrimary: false, isUp: true, ipv4: ["10.0.4.17"],
                                     macAddress: "00:e0:4c:68:01:2a", downBytesPerSec: 0, upBytesPerSec: 0)],
            wifi: WiFiInfo(ssid: "Hyperion-5G", rssi: -58, noise: -92, txRateMbps: 1201, channel: "149 (5 GHz, 80 MHz)", phyMode: "802.11be", security: "WPA3 Personal"),
            publicIPv4: "84.123.45.67", gateway: "192.168.1.1", dnsServers: ["192.168.1.1", "1.1.1.1"])
        st.fetchPublicIP = true
        st.netDownHistory = hist(series(n, base: 2_000_000, amp: 2_200_000, seed: 7, lo: 0))
        st.netUpHistory = hist(series(n, base: 150_000, amp: 180_000, seed: 8, lo: 0))
        // Sensors
        func t(_ id: String, _ name: String, _ g: SensorGroup, _ v: Double) -> Sensor { Sensor(id: id, name: name, group: g, value: v, unit: .celsius) }
        var temps: [Sensor] = []
        for i in 0..<6 { temps.append(t("Ts0\(i)", "CPU Super Core \(i + 1)", .cpu, 48 + Double(i) * 2.2)) }
        for i in 0..<12 { temps.append(t("Tp0\(i)", "CPU Performance Core \(i + 1)", .cpu, 42 + Double(i % 5) * 1.5)) }
        temps += [t("cpu.avg", "CPU Average", .cpu, 46.1), t("cpu.max", "CPU Max", .cpu, 58.4)]
        for i in 0..<8 { temps.append(t("Tg0\(i)", "GPU Cluster \(i + 1)", .gpu, 41 + Double(i))) }
        temps += [t("gpu.avg", "GPU Average", .gpu, 44.5), t("gpu.max", "GPU Max", .gpu, 49.2)]
        for i in 0..<5 { temps.append(t("Tm0\(i)", "Memory Die \(i + 1)", .memory, 40 + Double(i))) }
        temps += [t("TH0a", "SSD NAND 1", .storage, 38.5), t("TH0b", "SSD NAND 2", .storage, 37.9),
                  t("TB0T", "Battery 1", .battery, 31.4), t("TB1T", "Battery 2", .battery, 31.9),
                  t("TD00", "Display 1", .display, 36.2), t("TaLP", "Airflow Left", .enclosure, 29.8), t("TaRF", "Airflow Right", .enclosure, 30.1),
                  t("TW0P", "Wi‑Fi Module", .wireless, 34.4), t("TCHP", "Charger", .power, 33.0)]
        st.sensors = SensorsSnapshot(
            temperatures: temps,
            fans: [FanSample(id: 0, name: "Left Fan", rpm: 2480, minRPM: 1200, maxRPM: 6250, targetRPM: 2500),
                   FanSample(id: 1, name: "Right Fan", rpm: 2610, minRPM: 1200, maxRPM: 6750, targetRPM: 2600)],
            power: [Sensor(id: "PSTR", name: "System Total", group: .power, value: 16.8, unit: .watts),
                    Sensor(id: "PPBR", name: "Battery Rail", group: .power, value: 11.2, unit: .watts)],
            voltages: [Sensor(id: "VD0C", name: "DC In", group: .power, value: 19.96, unit: .volts)],
            currents: [Sensor(id: "IB0f", name: "Battery", group: .power, value: -0.82, unit: .amps)],
            battery: BatterySnapshot(present: true, percent: 0.78, isCharging: false, isPluggedIn: false, minutesRemaining: 412, cycleCount: 87,
                                     healthFraction: 0.98, designCapacitymAh: 6000, fullChargeCapacitymAh: 5880, temperatureC: 31.4,
                                     voltageV: 12.9, amperageA: -0.82, powerW: -10.6, adapterWatts: 96, adapterName: "USB-C"),
            cpuTemperature: 52.3, gpuTemperature: 44.5, systemPowerW: 16.8)
        st.cpuTempHistory = hist(series(n, base: 50, amp: 7, seed: 9))
        st.gpuTempHistory = hist(series(n, base: 44, amp: 4, seed: 10))
        st.systemPowerHistory = hist(series(n, base: 16, amp: 6, seed: 11, lo: 5))
        st.pinnedSensorIDs = ["Ts00"]
        return st
    }
}
