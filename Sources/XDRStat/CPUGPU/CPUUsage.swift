// Per-core usage via host_processor_info + logical CPU -> cluster topology.
//
// Topology (verified, see ChipSampler notes): read from IODeviceTree:/cpus nodes. Each cpuN has
// "logical-cpu-id", "cluster-id" and "cluster-type" ("P" = Super cores, "M" = Performance cores;
// matches IOReport PCPU* vs MCPU*). On this M5 Pro: logical 0-5 = cluster-id 0 type M (Performance 1, MCPU0x),
// 6-11 = cluster-id 1 type M (Performance 2, MCPU1x), 12-17 = cluster-id 2 type P (Super, PCPUn).
// NOTE: the Super cores are the HIGHEST logical indices, not the lowest.
import Foundation
import IOKit

struct CoreTopology {
    struct Entry { var kind: CoreKind; var cluster: Int; var indexInCluster: Int }
    var entries: [Int: Entry] = [:]   // logical cpu -> entry

    init(cpuCount: Int) {
        var raw: [(logical: Int, type: String, cid: Int)] = []
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if root != 0 {
            var it: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(root, "IODeviceTree", &it) == KERN_SUCCESS {
                var c = IOIteratorNext(it)
                while c != 0 {
                    func num(_ k: String) -> Int? {
                        guard let v = IORegistryEntryCreateCFProperty(c, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
                        if let n = v as? NSNumber { return n.intValue }
                        if let d = v as? Data, d.count >= 4 { return Int(d[0]) | Int(d[1]) << 8 | Int(d[2]) << 16 | Int(d[3]) << 24 }
                        return nil
                    }
                    var type = ""
                    if let v = IORegistryEntryCreateCFProperty(c, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                        if let d = v as? Data { type = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self) }
                        else if let s = v as? String { type = s }
                    }
                    if let l = num("logical-cpu-id"), let cid = num("cluster-id"), !type.isEmpty { raw.append((l, type, cid)) }
                    IOObjectRelease(c); c = IOIteratorNext(it)
                }
                IOObjectRelease(it)
            }
            IOObjectRelease(root)
        }
        if raw.count == cpuCount {
            // Super ("P") cluster -> 0; "M" clusters sorted by cluster-id -> 1, 2, ...
            let mIDs = Set(raw.filter { $0.type != "P" }.map { $0.cid }).sorted()
            var counters: [Int: Int] = [:]
            for r in raw.sorted(by: { $0.logical < $1.logical }) {
                let cluster = r.type == "P" ? 0 : (1 + (mIDs.firstIndex(of: r.cid) ?? 0))
                let idx = counters[cluster, default: 0]; counters[cluster] = idx + 1
                entries[r.logical] = Entry(kind: r.type == "P" ? .superCore : .performance, cluster: cluster, indexInCluster: idx)
            }
        } else {
            // Fallback from sysctl: assume performance cores (perflevel1) come first in 6-core clusters, super last.
            func si(_ n: String) -> Int { var v: Int32 = 0; var s = 4; sysctlbyname(n, &v, &s, nil, 0); return Int(v) }
            let nSuper = si("hw.perflevel0.logicalcpu")
            let perCluster = max(1, si("hw.perflevel1.cpusperl2"))
            let nPerf = cpuCount - nSuper
            for l in 0..<cpuCount {
                if l < nPerf { entries[l] = Entry(kind: .performance, cluster: 1 + l / perCluster, indexInCluster: l % perCluster) }
                else { entries[l] = Entry(kind: .superCore, cluster: 0, indexInCluster: l - nPerf) }
            }
        }
    }
}

final class CPUUsageSampler {
    private var prev: [UInt32] = []   // 4 per cpu
    let cpuCount: Int

    init() {
        var n: Int32 = 0; var s = 4
        sysctlbyname("hw.logicalcpu", &n, &s, nil, 0)
        cpuCount = Int(n)
    }

    /// (user, system) fractions per logical CPU; nil on first call.
    func sample() -> [(user: Double, system: Double)]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let n = Int(count)
        var cur = [UInt32](repeating: 0, count: n * 4)
        for i in 0..<n * 4 { cur[i] = UInt32(bitPattern: info[i]) }
        defer { prev = cur }
        guard prev.count == cur.count else { return nil }
        var out: [(Double, Double)] = []
        out.reserveCapacity(n)
        for c in 0..<n {
            let b = c * 4
            let u = Double(cur[b + 0] &- prev[b + 0]), s = Double(cur[b + 1] &- prev[b + 1])
            let i = Double(cur[b + 2] &- prev[b + 2]), nn = Double(cur[b + 3] &- prev[b + 3])
            let t = u + s + i + nn
            out.append(t > 0 ? ((u + nn) / t, s / t) : (0, 0))
        }
        return out
    }
}
