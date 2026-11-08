import Foundation
import Darwin

/// Memory statistics, following Activity Monitor conventions:
///   app        = internal_page_count - purgeable_count   ("App Memory")
///   wired      = wire_count
///   compressed = compressor_page_count                   ("Compressed")
///   used       = app + wired + compressed                ("Memory Used")
///   cached     = external_page_count + purgeable_count   ("Cached Files")
///   free       = free_count - speculative_count          (same as `vm_stat` "Pages free";
///                speculative pages are file-backed and already inside external_page_count)
///
/// Pressure: kern.memorystatus_level is the kernel's "percent of memory available" figure
/// (it drives the same memorystatus thresholds Activity Monitor's pressure graph reflects),
/// so continuous = 1 - level/100. The discrete kern.memorystatus_vm_pressure_level
/// (1 normal / 2 warn / 4 critical) sets floors (0.5 / 0.8) so colour bands always
/// agree with the OS's verdict.
final class MemorySampler {
    private let grouper = AppGrouper()
    private var lastPageIns: UInt64 = 0
    private var lastPageOuts: UInt64 = 0
    private var lastTime: UInt64 = 0
    private var haveLast = false
    private var nameCache: [Int32: String] = [:]
    private let pageSize = UInt64(vm_kernel_page_size)
    private let totalMem: UInt64 = {
        var v: UInt64 = 0; var s = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &s, nil, 0); return v
    }()

    private func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0; var s = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &s, nil, 0) == 0 ? v : nil
    }

    func sample(detailed: Bool) -> MemorySnapshot {
        var snap = MemorySnapshot()
        snap.total = totalMem

        var st = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &st) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let ps = pageSize
            let internalPages = UInt64(st.internal_page_count)
            let purg = UInt64(st.purgeable_count)
            let app = (internalPages > purg ? internalPages - purg : 0) * ps
            let wired = UInt64(st.wire_count) * ps
            let comp = UInt64(st.compressor_page_count) * ps
            snap.app = app; snap.wired = wired; snap.compressed = comp
            snap.used = app + wired + comp
            snap.cached = (UInt64(st.external_page_count) + purg) * ps
            let freePages = st.free_count > st.speculative_count ? st.free_count - st.speculative_count : 0
            snap.free = UInt64(freePages) * ps
            if st.compressor_page_count > 0 && st.total_uncompressed_pages_in_compressor > 0 {
                snap.compressionRatio = Double(st.total_uncompressed_pages_in_compressor) / Double(st.compressor_page_count)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if haveLast {
                let dt = Double(now &- lastTime) / 1e9
                if dt > 0.05 {
                    snap.pageInsPerSec = Double(st.pageins >= lastPageIns ? st.pageins - lastPageIns : 0) / dt
                    snap.pageOutsPerSec = Double(st.pageouts >= lastPageOuts ? st.pageouts - lastPageOuts : 0) / dt
                }
            }
            lastPageIns = st.pageins; lastPageOuts = st.pageouts; lastTime = now; haveLast = true
        }

        // Pressure
        let levelPct = Double(sysctlInt32("kern.memorystatus_level") ?? 100)
        var pressure = max(0, min(1, 1 - levelPct / 100))
        switch sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: snap.pressureLevel = .critical; pressure = max(pressure, 0.8)
        case 2: snap.pressureLevel = .warning; pressure = max(pressure, 0.5)
        default: snap.pressureLevel = .normal; pressure = min(pressure, 0.49)
        }
        snap.pressure = pressure

        // Swap
        var sw = xsw_usage(); var sws = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sws, nil, 0) == 0 {
            snap.swapUsed = sw.xsu_used; snap.swapTotal = sw.xsu_total
        }

        if detailed { snap.topProcesses = topProcesses(limit: 8) }
        return snap
    }

    private func topProcesses(limit: Int) -> [ProcessUsage] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        var rows: [(Int32, UInt64)] = []
        rows.reserveCapacity(Int(got))
        var live = Set<Int32>()
        for i in 0..<Int(got) {
            let pid = pids[i]
            if pid <= 0 { continue }
            var ru = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if r != 0 { continue }
            live.insert(pid)
            rows.append((pid, ru.ri_phys_footprint))
        }
        // Name only the largest few hundred; the long tail can't make the top list once grouped.
        rows.sort { $0.1 > $1.1 }
        var named: [(pid: Int32, cpu: Double, mem: UInt64, name: String)] = []
        for (pid, bytes) in rows.prefix(300) {
            var name = nameCache[pid]
            if name == nil {
                var buf = [CChar](repeating: 0, count: 256)
                let l = proc_name(pid, &buf, UInt32(buf.count))
                name = l > 0 ? String(cString: buf) : "pid \(pid)"
                nameCache[pid] = name
            }
            named.append((pid: pid, cpu: 0, mem: bytes, name: name!))
        }
        let out = grouper.group(named, limit: limit, byCPU: false)
        grouper.prune(live: live)
        nameCache = nameCache.filter { live.contains($0.key) }   // every call: recycled pids get fresh names
        return out
    }
}
