// Groups helper processes under the app that owns them (like iStat Menus / Activity Monitor's app view):
// "Google Chrome Helper (Renderer)" ×20 → one "Google Chrome" row with the summed CPU / memory.
// Also names processes, so the CPU and memory lists agree. OWNER: lead. Used by the CPU and memory
// samplers on their background queue (not thread-safe; each sampler owns its own instance).

import Darwin
import Foundation

final class AppGrouper {
    struct Row { var pid: Int32; var start: UInt64; var cpu: Double; var mem: UInt64 }

    private struct Owner { var key: String; var name: String; var appPath: String?; var start: UInt64 }
    private var cache: [Int32: Owner] = [:]

    /// Groups rows by owning app and returns the top `limit` by CPU or memory.
    func group(_ rows: [Row], limit: Int, byCPU: Bool) -> [ProcessUsage] {
        var groups: [String: (usage: ProcessUsage, lead: Double)] = [:]
        for r in rows {
            let o = owner(r.pid, start: r.start)
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
            let a = byCPU ? $0.cpuPercent : Double($0.memoryBytes)
            let b = byCPU ? $1.cpuPercent : Double($1.memoryBytes)
            return a != b ? a > b : $0.name < $1.name   // stable order for ties, so rows don't flicker
        }
        return Array(sorted.prefix(limit))
    }

    /// Drop cached owners for pids that no longer exist.
    func prune(live: Set<Int32>) {
        cache = cache.filter { live.contains($0.key) }
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

    private static func shortName(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private func owner(_ pid: Int32, start: UInt64) -> Owner {
        // The start time guards against a recycled pid inheriting a dead process's name or app.
        if let o = cache[pid], o.start == start { return o }
        guard var path = Self.path(of: pid) else {
            // Caught mid-spawn or exiting: name it, but don't cache, so a later lookup can do better.
            return Owner(key: "pid:\(pid)", name: Self.shortName(of: pid) ?? "pid \(pid)", appPath: nil, start: start)
        }
        let exe = (path as NSString).lastPathComponent
        // XPC services (e.g. com.apple.WebKit.WebContent) run on behalf of an app; like Activity Monitor,
        // charge them to their "responsible" app. Only for .xpc bundles: CLI tools would otherwise be
        // charged to the terminal that launched them.
        if !path.contains(".app/"), path.contains(".xpc/") {
            let r = AppGrouper.responsiblePid(pid)
            if r != pid, let rp = Self.path(of: r), rp.contains(".app/") { path = rp }
        }
        var o = Owner(key: "pid:\(pid)", name: exe.isEmpty ? (Self.shortName(of: pid) ?? "pid \(pid)") : exe, appPath: nil, start: start)
        // Outermost bundle: the first "*.app" path component.
        if let r = path.range(of: ".app/") {
            let app = String(path[..<r.lowerBound]) + ".app"
            var name = FileManager.default.displayName(atPath: app)
            if name.hasSuffix(".app") { name.removeLast(4) }
            o = Owner(key: app, name: name, appPath: app, start: start)
        }
        cache[pid] = o
        return o
    }
}
