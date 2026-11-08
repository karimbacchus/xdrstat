// Process counts and top-CPU process list from proc_pid_rusage deltas.
import Foundation
import Darwin

final class ProcessSampler {
    private let grouper = AppGrouper()
    private struct State { var cpuNs: UInt64; var start: UInt64 }
    private var state: [Int32: State] = [:]
    private var lastScan: UInt64 = 0          // mach_absolute_time ns (pauses during sleep, like the counters)
    private var names: [Int32: String] = [:]
    private let tb: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    private var pidBuf = [pid_t](repeating: 0, count: 2048)

    private func toNs(_ t: UInt64) -> UInt64 {
        // Mach absolute units on Apple Silicon (timebase 125/3 on M1; 1/1 elsewhere) -> ns
        UInt64(Double(t) * Double(tb.numer) / Double(tb.denom))
    }

    private func listPids() -> [pid_t] {
        var n = proc_listallpids(nil, 0)
        if n <= 0 { return [] }
        if pidBuf.count < Int(n) + 64 { pidBuf = [pid_t](repeating: 0, count: Int(n) + 256) }
        n = pidBuf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(pidBuf.prefix(Int(n))) : []
    }

    func processCount() -> Int { Int(max(0, proc_listallpids(nil, 0))) }

    func sample(detailed: Bool) -> (processes: Int, threads: Int, top: [ProcessUsage]) {
        guard detailed else { return (processCount(), 0, []) }
        let pids = listPids()
        let nowNs = toNs(mach_absolute_time())
        let elapsedNs = lastScan == 0 ? 0 : Double(nowNs &- lastScan)
        var newState: [Int32: State] = [:]
        newState.reserveCapacity(pids.count)
        var rows: [(pid: Int32, pct: Double, mem: UInt64)] = []
        var threads = 0
        for pid in pids where pid > 0 {
            var ri = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if rc != 0 { continue }   // other users' processes: skip silently
            let cpu = toNs(ri.ri_user_time &+ ri.ri_system_time)
            newState[pid] = State(cpuNs: cpu, start: ri.ri_proc_start_abstime)
            var ti = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 { threads += Int(ti.pti_threadnum) }
            if elapsedNs > 0, let old = state[pid], old.start == ri.ri_proc_start_abstime, cpu >= old.cpuNs {
                let pct = Double(cpu - old.cpuNs) / elapsedNs * 100
                if pct > 0.05 { rows.append((pid, pct, ri.ri_phys_footprint)) }
            }
        }
        state = newState
        lastScan = nowNs
        rows.sort { $0.pct > $1.pct }
        let top = grouper.group(rows.map { (pid: $0.pid, cpu: $0.pct, mem: $0.mem, name: name(for: $0.pid)) }, limit: 8, byCPU: true)
        grouper.prune(live: Set(newState.keys))
        // prune name cache
        names = names.filter { newState[$0.key] != nil }   // also guards against pid reuse
        return (pids.count, threads, top)
    }

    private func name(for pid: Int32) -> String {
        if let n = names[pid] { return n }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var n = ""
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            n = (String(cString: buf) as NSString).lastPathComponent
        }
        if n.isEmpty {
            var b2 = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &b2, UInt32(b2.count)) > 0 { n = String(cString: b2) }
        }
        if n.isEmpty { n = "pid \(pid)" }
        names[pid] = n
        return n
    }
}
