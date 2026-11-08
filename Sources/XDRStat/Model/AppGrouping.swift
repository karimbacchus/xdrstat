// Groups helper processes under the app that owns them (like iStat Menus / Activity Monitor's app view):
// "Google Chrome Helper (Renderer)" ×20 → one "Google Chrome" row with the summed CPU / memory.
// OWNER: lead. Used by the CPU and memory samplers on their background queue (not thread-safe;
// each sampler owns its own instance).

import Darwin
import Foundation

final class AppGrouper {
    private struct Owner { var key: String; var name: String; var appPath: String? }
    private var cache: [Int32: Owner] = [:]

    /// rows: (pid, cpu %, footprint bytes, fallback name). Returns the top `limit` grouped rows.
    func group(_ rows: [(pid: Int32, cpu: Double, mem: UInt64, name: String)], limit: Int, byCPU: Bool) -> [ProcessUsage] {
        var groups: [String: (usage: ProcessUsage, lead: Double)] = [:]
        for r in rows {
            let o = owner(r.pid, fallback: r.name)
            let weight = byCPU ? r.cpu : Double(r.mem)
            if var g = groups[o.key] {
                g.usage.cpuPercent += r.cpu
                g.usage.memoryBytes += r.mem
                if weight > g.lead { g.usage.pid = r.pid; g.lead = weight }   // icon/tooltip from the biggest member
                groups[o.key] = g
            } else {
                groups[o.key] = (ProcessUsage(pid: r.pid, name: o.name, cpuPercent: r.cpu, memoryBytes: r.mem, appPath: o.appPath), weight)
            }
        }
        let sorted = groups.values.map(\.usage).sorted {
            byCPU ? $0.cpuPercent > $1.cpuPercent : $0.memoryBytes > $1.memoryBytes
        }
        return Array(sorted.prefix(limit))
    }

    /// Drop cached owners for pids that no longer exist.
    func prune(live: Set<Int32>) {
        if cache.count > live.count + 64 { cache = cache.filter { live.contains($0.key) } }
    }

    /// `responsibility_get_pid_responsible_for_pid` (libSystem, undocumented) — looked up once via dlsym.
    private static let responsibleFn: (@convention(c) (Int32) -> Int32)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Int32) -> Int32).self)
    }()
    static func responsiblePid(_ pid: Int32) -> Int32 {
        guard let f = responsibleFn else { return pid }
        let r = f(pid)
        return r > 0 ? r : pid
    }

    private static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private func owner(_ pid: Int32, fallback: String) -> Owner {
        if let o = cache[pid] { return o }
        var o = Owner(key: "pid:\(pid)", name: fallback, appPath: nil)
        guard var path = Self.path(of: pid) else { cache[pid] = o; return o }
        // XPC services (e.g. com.apple.WebKit.WebContent) run on behalf of an app; like Activity Monitor,
        // charge them to their "responsible" app. Only for .xpc bundles: CLI tools would otherwise be
        // charged to the terminal that launched them.
        if !path.contains(".app/"), path.contains(".xpc/") {
            let r = AppGrouper.responsiblePid(pid)
            if r != pid, let rp = Self.path(of: r), rp.contains(".app/") { path = rp }
        }
        do {
            // Outermost bundle: the first "*.app" path component.
            if let r = path.range(of: ".app/") {
                let app = String(path[..<r.lowerBound]) + ".app"
                var name = FileManager.default.displayName(atPath: app)
                if name.hasSuffix(".app") { name.removeLast(4) }
                o = Owner(key: app, name: name, appPath: app)
            }
        }
        cache[pid] = o
        return o
    }
}
