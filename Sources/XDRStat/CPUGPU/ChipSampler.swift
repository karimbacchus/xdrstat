// ChipSampler: CPU / GPU / SoC power snapshot, called ~1 Hz from a serial queue.
//
// Verified on Mac17,12 (see CPUUsage.swift): logical CPUs 0-5 = Performance cluster 1 (IOReport MCPU0x),
// 6-11 = Performance cluster 2 (MCPU1x), 12-17 = Super cluster (PCPUn / PACC_n).
// Frequency table mapping is documented in Frequency.swift.
import Foundation

final class ChipSampler {
    private let report = IOReportSession()
    private let usage = CPUUsageSampler()
    private let topology: CoreTopology
    private let freq = FrequencyTables()
    private let gpuReader = GPUInfoReader()
    private let procs = ProcessSampler()
    private let gpuTable: [Double]?
    private let chipName: String
    private let bootTime: Date?
    private var tick = 0
    // The Energy Model counters (mJ) are refreshed by the kernel on its own schedule: every couple of
    // seconds at best, and only about every five minutes in some states (seen on mains power, macOS 27.3).
    // Joules are therefore accumulated until the sentinel channel moves, and watts are the average over
    // that real window. The first jump is skipped: it covers a window that began before we were watching.
    private struct EnergyWindow {
        var joules: [String: Double] = [:]
        var secs = 0.0
        var seenFirst = false
        var watts: [String: Double] = [:]
        var gap: Double?            // length of the last complete window
        var sinceUpdate = 0.0
        var lastElapsed = 0.0       // most recent elapsed passed to add(); the refresh period
        /// The averages are recent enough to show as live values: the last complete window was no longer
        /// than about two refresh periods (so a slow sampler isn't judged stale) and one is not overdue.
        var isLive: Bool {
            (gap ?? .infinity) <= max(6, 2.5 * lastElapsed) && sinceUpdate <= max(8, 3 * lastElapsed)
        }

        mutating func add(elapsed: Double, sentinel: String) {
            lastElapsed = elapsed
            secs += elapsed; sinceUpdate += elapsed
            guard (joules[sentinel] ?? 0) > 0 else { return }
            if seenFirst, secs > 0 { watts = joules.mapValues { $0 / secs }; gap = secs }
            seenFirst = true
            joules = [:]; secs = 0; sinceUpdate = 0
        }
    }
    private var socAcc = EnergyWindow()
    private var gpuAcc = EnergyWindow()

    /// Everything derived from IOReport (power and frequencies). Only the CPU panel shows these, so
    /// while it's closed they're refreshed every 4th tick and reused in between: still warm when the
    /// panel opens, without a full IOReport sample (~3 ms) every second.
    private struct ReportValues {
        var coreFreq: [Int: Double] = [:], corePower: [Int: Double] = [:]
        var clusterFreq: [Int: Double] = [:], clusterMax: [Int: Double] = [:], clusterPower: [Int: Double] = [:]
        var cpuPower: Double?, gpuFreq: Double?, gpuPower: Double?
        var cpuPowerEstimated = false
        var components: [PowerComponent] = []
    }
    private var reportValues = ReportValues()

    init() {
        topology = CoreTopology(cpuCount: usage.cpuCount)
        gpuTable = freq.gpuTable()
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let brandStr = String(cString: brand)
        chipName = gpuReader.model ?? (brandStr.isEmpty ? "Apple M5" : brandStr)
        var tv = timeval(); var tvs = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        bootTime = sysctl(&mib, 2, &tv, &tvs, nil, 0) == 0 ? Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)) : nil
        _ = usage.sample()          // prime deltas
        _ = report?.sampleDelta()
    }

    // Short names: the CPU panel's power legend is two narrow columns.
    private static let friendly: [(String, String)] = [
        ("ANE", "ANE"), ("DRAM", "DRAM"), ("DISPEXT", "Ext Display"), ("DISP", "Display"),
        ("FAB", "Fabric"), ("AMCC", "Mem Ctrl"), ("DCS", "DCS"), ("AVE", "Media"),
        ("ISP", "ISP"), ("MSR", "Scaler"), ("AFR", "AFR"), ("PCIe Port", "PCIe"), ("apciec", "PCIe")
    ]

    func sample(detailed: Bool) -> ChipSnapshot {
        autoreleasepool { sampleImpl(detailed: detailed) }
    }

    /// The CPU panel opened: take the baseline process scan now.
    func beginProcessSampling() { procs.prime() }

    /// Shortly after `beginProcessSampling`: the first per-process list, unless a regular tick already made one.
    func processesIfStillPending() -> ProcessSampler.Result? {
        procs.awaitingFirstList ? procs.sample(detailed: true) : nil
    }

    private func stateChannelName(_ e: CoreTopology.Entry) -> String {
        e.cluster == 0 ? "PCPU\(e.indexInCluster)" : "MCPU\(e.cluster - 1)\(e.indexInCluster)"
    }
    private func energyChannelName(_ e: CoreTopology.Entry) -> String {
        e.cluster == 0 ? "PACC_\(e.indexInCluster)" : "MCPU\(e.cluster - 1)_\(e.indexInCluster)"
    }

    private func refreshReport() {
        guard let delta = report?.sampleDelta() else { return }
        var cpuStates: [String: [(name: String, residency: Int64)]] = [:]
        var gpuStates: [(name: String, residency: Int64)] = []
        var powerBins: [String: [(name: String, residency: Int64)]] = [:]
        for c in delta.channels {
            if c.group == "Energy Model" {
                let j = IOReportSession.joules(c)
                if c.name == "GPU Energy" { gpuAcc.joules[c.name, default: 0] += j }
                else { socAcc.joules[c.name, default: 0] += j }
            } else if c.group == "CPU Stats" {
                cpuStates[c.name] = c.states
            } else if c.group == "GPU Stats", c.name == "GPUPH" {
                gpuStates = c.states
            } else if c.group == "PMP0" {
                powerBins[c.name] = c.states
            }
        }
        socAcc.add(elapsed: delta.elapsed, sentinel: "CPU Energy")
        gpuAcc.add(elapsed: delta.elapsed, sentinel: "GPU Energy")
        var watts = socAcc.watts.merging(gpuAcc.watts) { a, _ in a }
        // When the exact CPU counters are stale, estimate each cluster live from the power-management
        // processor's power histogram for it (2 W bins, sampled ~2 kHz). Everything else in the SoC
        // breakdown then shows its average over the last counter window.
        let estimated = !socAcc.isLive
        if estimated {
            var total = 0.0, any = false
            for (bins, channel) in [("PACC", "PCPU"), ("MACC0", "MCPU0"), ("MACC1", "MCPU1")] {
                guard let w = Self.meanPower(powerBins[bins]) else { watts[channel] = nil; continue }
                watts[channel] = w; total += w; any = true
            }
            watts["CPU Energy"] = any ? total : nil
            for k in watts.keys where k.hasPrefix("PACC_") || (k.hasPrefix("MCPU") && k.contains("_")) { watts[k] = nil }   // no per-core split
        }

        var v = ReportValues()
        var tableCache: [Int: [Double]?] = [:]
        func cpuTable(for states: [(name: String, residency: Int64)]) -> [Double]? {
            let n = states.filter { $0.name.hasPrefix("V") }.count
            if let t = tableCache[n] { return t }
            let t = freq.cpuTable(count: n); tableCache[n] = t; return t
        }
        var clusterFreqSum: [Int: (sum: Double, w: Double)] = [:]
        for l in 0..<usage.cpuCount {
            guard let e = topology.entries[l] else { continue }
            v.corePower[l] = watts[energyChannelName(e)]
            guard let st = cpuStates[stateChannelName(e)] else { continue }
            let table = cpuTable(for: st)
            if let a = FrequencyMath.cpuActive(st, table: table) {
                v.coreFreq[l] = a.mhz
                var cur = clusterFreqSum[e.cluster] ?? (0, 0)
                cur.sum += a.mhz * a.weight; cur.w += a.weight
                clusterFreqSum[e.cluster] = cur
            }
            if let m = table?.max() { v.clusterMax[e.cluster] = m }
        }
        for (cl, f) in clusterFreqSum where f.w > 0 { v.clusterFreq[cl] = f.sum / f.w }
        for cl in Set(topology.entries.values.map(\.cluster)) {
            v.clusterPower[cl] = watts[cl == 0 ? "PCPU" : "MCPU\(cl - 1)"]
        }
        v.cpuPower = watts["CPU Energy"]
        v.gpuFreq = FrequencyMath.gpuActive(gpuStates, table: gpuTable)
        // "GPU Energy" (nJ) is preferred; "GPU0" (mJ) is a coarser fallback.
        v.gpuPower = watts["GPU Energy"] ?? watts["GPU0"]
        var comps: [String: Double] = [:]
        let skip: Set<String> = ["GPU0", "GPU Energy", "CPU Energy"]
        for (name, w) in watts where w > 0.01 && !skip.contains(name) {
            guard let f = Self.friendly.first(where: { name.hasPrefix($0.0) })?.1 else { continue }
            comps[f, default: 0] += w
        }
        v.components = comps.map { PowerComponent(name: $0.key, watts: $0.value) }.sorted { $0.watts > $1.watts }
        v.cpuPowerEstimated = estimated && v.cpuPower != nil
        reportValues = v
    }

    /// Mean of a power histogram whose states are labelled with each bin's upper bound ("   2W", "   4W", …).
    /// Idle samples all land in the lowest bin, whose true mean is far below its midpoint, so that bin is
    /// weighted at 15% of its width (about 0.3 W for a CPU cluster's 2 W bin).
    private static func meanPower(_ bins: [(name: String, residency: Int64)]?) -> Double? {
        guard let bins, !bins.isEmpty else { return nil }
        var sum = 0.0, n = 0.0
        for (i, b) in bins.enumerated() where b.residency > 0 {
            guard let upper = Double(b.name.trimmingCharacters(in: .whitespaces).dropLast()), upper > 0 else { continue }
            let width = upper / Double(i + 1)
            let r = Double(b.residency)
            sum += r * (i == 0 ? width * 0.15 : upper - width / 2)
            n += r
        }
        return n > 0 ? sum / n : nil
    }

    private func sampleImpl(detailed: Bool) -> ChipSnapshot {
        tick += 1
        if detailed || tick % 4 == 0 { refreshReport() }
        let rv = reportValues

        var snap = ChipSnapshot()
        snap.chipName = chipName
        let u = usage.sample()
        var cores: [CoreSample] = []
        for l in 0..<usage.cpuCount {
            guard let e = topology.entries[l] else { continue }
            let (user, system) = u.map { l < $0.count ? ($0[l].user, $0[l].system) : (0, 0) } ?? (0, 0)
            cores.append(CoreSample(id: l, kind: e.kind, cluster: e.cluster, user: user, system: system,
                                    frequencyMHz: rv.coreFreq[l], powerW: rv.corePower[l]))
        }
        snap.cpu.cores = cores

        let names = [0: "Super", 1: "Performance 1", 2: "Performance 2"]
        for cl in Set(cores.map { $0.cluster }).sorted() {
            let members = cores.filter { $0.cluster == cl }
            let avg = members.isEmpty ? 0 : members.map { $0.usage }.reduce(0, +) / Double(members.count)
            snap.cpu.clusters.append(ClusterSample(id: cl, name: names[cl] ?? "Cluster \(cl)",
                                                   kind: members.first?.kind ?? .performance, usage: avg,
                                                   frequencyMHz: rv.clusterFreq[cl], maxFrequencyMHz: rv.clusterMax[cl],
                                                   powerW: rv.clusterPower[cl]))
        }

        if !cores.isEmpty {
            snap.cpu.user = cores.map { $0.user }.reduce(0, +) / Double(cores.count)
            snap.cpu.system = cores.map { $0.system }.reduce(0, +) / Double(cores.count)
            snap.cpu.idle = max(0, 1 - snap.cpu.user - snap.cpu.system)
        }
        snap.cpu.powerW = rv.cpuPower
        snap.cpu.powerIsEstimate = rv.cpuPowerEstimated

        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        snap.cpu.loadAverage = la
        if let b = bootTime { snap.cpu.uptime = max(0, Date().timeIntervalSince(b)) }
        let p = procs.sample(detailed: detailed)
        snap.cpu.processCount = p.processes
        snap.cpu.threadCount = p.threads
        snap.cpu.topProcesses = p.top

        let g = gpuReader.stats()
        snap.gpu.name = chipName
        snap.gpu.coreCount = gpuReader.coreCount
        snap.gpu.utilization = g.device
        snap.gpu.rendererUtilization = g.renderer
        snap.gpu.tilerUtilization = g.tiler
        snap.gpu.memoryInUseBytes = g.inUse
        snap.gpu.memoryAllocatedBytes = g.alloc
        snap.gpu.maxFrequencyMHz = gpuTable?.max()
        snap.gpu.frequencyMHz = rv.gpuFreq
        snap.gpu.powerW = rv.gpuPower
        snap.components = rv.components
        return snap
    }
}
