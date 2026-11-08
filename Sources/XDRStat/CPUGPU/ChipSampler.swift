// ChipSampler: CPU / GPU / SoC power snapshot, called ~1 Hz from a serial queue.
//
// Verified on Mac17,12 (see CPUUsage.swift): logical CPUs 0-5 = Performance cluster 1 (IOReport MCPU0x),
// 6-11 = Performance cluster 2 (MCPU1x), 12-17 = Super cluster (PCPUn / PACC_n).
// Frequency table mapping is documented in Frequency.swift.
import Foundation

final class ChipSampler {
    private let ior = IOReportSession()
    private let usage = CPUUsageSampler()
    private let topology: CoreTopology
    private let freq = FrequencyTables()
    private let gpuReader = GPUInfoReader()
    private let procs = ProcessSampler()
    private let gpuTable: [Double]?
    private let chipName: String
    private let bootTime: Date?
    // The Energy Model counters only advance about every other 1 s tick (a tick often reads exactly 0 mJ
    // on every channel). Joules are therefore accumulated until the sentinel channel moves, and watts are
    // computed over the full accumulated real time. Separate accumulators for the SoC group and GPU Energy.
    private struct Acc { var joules: [String: Double] = [:]; var secs = 0.0; var lastWatts: [String: Double] = [:] }
    private var socAcc = Acc()
    private var gpuAcc = Acc()

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
        _ = ior?.sampleDelta()
    }

    private static let friendly: [(String, String)] = [
        ("ANE", "ANE"), ("DRAM", "DRAM"), ("DISPEXT", "External Display"), ("DISP", "Display"),
        ("FAB", "Fabric"), ("AMCC", "Memory Controller"), ("DCS", "DRAM Controller"), ("AVE", "Media Engine"),
        ("ISP", "ISP"), ("MSR", "Media Scaler"), ("AFR", "AFR"), ("PCIe Port", "PCIe"), ("apciec", "PCIe")
    ]

    func sample(detailed: Bool) -> ChipSnapshot {
        autoreleasepool { sampleImpl(detailed: detailed) }
    }

    private func sampleImpl(detailed: Bool) -> ChipSnapshot {
        var snap = ChipSnapshot()
        snap.chipName = chipName
        let delta = ior?.sampleDelta()
        let secs = delta?.elapsed ?? 1

        var watts: [String: Double] = [:]
        var cpuStates: [String: [(name: String, residency: Int64)]] = [:]
        var gpuStates: [(name: String, residency: Int64)] = []
        if let delta {
            for c in delta.channels {
                if c.group == "Energy Model" {
                    let j = IOReportSession.joules(c)
                    if c.name == "GPU Energy" { gpuAcc.joules[c.name, default: 0] += j }
                    else { socAcc.joules[c.name, default: 0] += j }
                } else if c.group == "CPU Stats" {
                    cpuStates[c.name] = c.states
                } else if c.group == "GPU Stats", c.name == "GPUPH" {
                    gpuStates = c.states
                }
            }
        }

        if delta != nil {
            for which in 0..<2 {
                var acc = which == 0 ? socAcc : gpuAcc
                acc.secs += secs
                let sentinel = which == 0 ? "CPU Energy" : "GPU Energy"
                if (acc.joules[sentinel] ?? 0) > 0 {
                    acc.lastWatts = acc.joules.mapValues { $0 / acc.secs }
                    acc.joules = [:]; acc.secs = 0
                } else if acc.secs > 10 {   // counters genuinely stuck at zero: report zeros
                    acc.lastWatts = acc.joules.mapValues { $0 / acc.secs }
                    acc.joules = [:]; acc.secs = 0
                }
                if which == 0 { socAcc = acc } else { gpuAcc = acc }
            }
        }
        watts = socAcc.lastWatts.merging(gpuAcc.lastWatts) { a, _ in a }

        let u = usage.sample()
        var cores: [CoreSample] = []
        let n = usage.cpuCount
        func stateChannelName(_ e: CoreTopology.Entry) -> String {
            e.cluster == 0 ? "PCPU\(e.indexInCluster)" : "MCPU\(e.cluster - 1)\(e.indexInCluster)"
        }
        func energyChannelName(_ e: CoreTopology.Entry) -> String {
            e.cluster == 0 ? "PACC_\(e.indexInCluster)" : "MCPU\(e.cluster - 1)_\(e.indexInCluster)"
        }
        var tableCache: [Int: [Double]?] = [:]
        func cpuTable(for states: [(name: String, residency: Int64)]) -> [Double]? {
            let v = states.filter { $0.name.hasPrefix("V") }.count
            if let t = tableCache[v] { return t }
            let t = freq.cpuTable(count: v); tableCache[v] = t; return t
        }
        var clusterFreqSum: [Int: (sum: Double, w: Double)] = [:]
        var clusterMax: [Int: Double] = [:]
        for l in 0..<n {
            guard let e = topology.entries[l] else { continue }
            let st = cpuStates[stateChannelName(e)]
            let table = st.flatMap { cpuTable(for: $0) }
            var core = CoreSample(id: l, kind: e.kind, cluster: e.cluster,
                                  user: u?[l].user ?? 0, system: u?[l].system ?? 0,
                                  frequencyMHz: nil, powerW: watts[energyChannelName(e)])
            if let st, let a = FrequencyMath.cpuActive(st, table: table) {
                core.frequencyMHz = a.mhz
                var cur = clusterFreqSum[e.cluster] ?? (0, 0)
                cur.sum += a.mhz * a.weight; cur.w += a.weight
                clusterFreqSum[e.cluster] = cur
            }
            if let t = table, let m = t.max() { clusterMax[e.cluster] = m }
            cores.append(core)
        }
        cores.sort { $0.id < $1.id }
        snap.cpu.cores = cores

        let names = [0: "Super", 1: "Performance 1", 2: "Performance 2"]
        for cl in Set(cores.map { $0.cluster }).sorted() {
            let members = cores.filter { $0.cluster == cl }
            let avg = members.isEmpty ? 0 : members.map { $0.usage }.reduce(0, +) / Double(members.count)
            let ch = cl == 0 ? "PCPU" : "MCPU\(cl - 1)"
            let f = clusterFreqSum[cl].flatMap { $0.w > 0 ? $0.sum / $0.w : nil }
            snap.cpu.clusters.append(ClusterSample(id: cl, name: names[cl] ?? "Cluster \(cl)",
                                                   kind: members.first?.kind ?? .performance, usage: avg,
                                                   frequencyMHz: f, maxFrequencyMHz: clusterMax[cl], powerW: watts[ch]))
        }

        if !cores.isEmpty {
            snap.cpu.user = cores.map { $0.user }.reduce(0, +) / Double(cores.count)
            snap.cpu.system = cores.map { $0.system }.reduce(0, +) / Double(cores.count)
            snap.cpu.idle = max(0, 1 - snap.cpu.user - snap.cpu.system)
        }
        snap.cpu.powerW = watts["CPU Energy"]

        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        snap.cpu.loadAverage = la
        if let b = bootTime { snap.cpu.uptime = max(0, Date().timeIntervalSince(b)) }
        let p = procs.sample(detailed: detailed)
        snap.cpu.processCount = p.processes
        if detailed { snap.cpu.threadCount = p.threads }
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
        snap.gpu.frequencyMHz = FrequencyMath.gpuActive(gpuStates, table: gpuTable)
        // "GPU Energy" (nJ) is preferred; "GPU0" (mJ) is a coarser fallback.
        snap.gpu.powerW = watts["GPU Energy"] ?? watts["GPU0"]

        var comps: [String: Double] = [:]
        let skip: Set<String> = ["GPU0", "GPU Energy", "CPU Energy"]
        for (name, w) in watts where w > 0.01 && !skip.contains(name) {
            guard let f = Self.friendly.first(where: { name.hasPrefix($0.0) })?.1 else { continue }
            comps[f, default: 0] += w
        }
        snap.components = comps.map { PowerComponent(name: $0.key, watts: $0.value) }.sorted { $0.watts > $1.watts }
        return snap
    }
}
