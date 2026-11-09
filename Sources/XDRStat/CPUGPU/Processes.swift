// Process counts and top-CPU process list from proc_pid_rusage deltas.
import Foundation
import Darwin

final class ProcessSampler {
    struct Result { var processes = 0; var threads = 0; var top: [ProcessUsage] = [] }

    private let grouper = AppGrouper()
    private struct State { var cpuNs: UInt64; var start: UInt64 }
    private var state: [Int32: State] = [:]
    private var lastScan: UInt64 = 0          // mach_absolute_time ns (pauses during sleep, like the counters)
    private let tb: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    private var pidBuf = [pid_t](repeating: 0, count: 2048)
    /// A baseline scan exists but no list has been computed from it yet.
    private(set) var awaitingFirstList = false

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

    /// Baseline scan so the next `sample(detailed: true)` can compute CPU percentages.
    func prime() {
        _ = scan()
        awaitingFirstList = true
    }

    func sample(detailed: Bool) -> Result {
        guard detailed else {
            // Panel closed: drop the baseline, or the first list after reopening would show averages
            // over the whole time it was closed.
            if lastScan != 0 { state = [:]; lastScan = 0; awaitingFirstList = false }
            return Result()
        }
        let hadBaseline = lastScan != 0
        let r = scan()
        if hadBaseline { awaitingFirstList = false }
        return r
    }

    private func scan() -> Result {
        let pids = listPids()
        let nowNs = toNs(mach_absolute_time())
        let elapsedNs = lastScan == 0 ? 0 : Double(nowNs &- lastScan)
        var newState: [Int32: State] = [:]
        newState.reserveCapacity(pids.count)
        var rows: [AppGrouper.Row] = []
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
                if pct > 0.05 { rows.append(AppGrouper.Row(pid: pid, start: ri.ri_proc_start_abstime, cpu: pct, mem: ri.ri_phys_footprint)) }
            }
        }
        state = newState
        lastScan = nowNs
        let top = grouper.group(rows, limit: 8, byCPU: true)
        grouper.prune(live: Set(newState.keys))
        return Result(processes: pids.count, threads: threads, top: top)
    }
}
