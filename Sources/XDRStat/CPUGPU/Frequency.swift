// Frequency tables from the pmgr node (IORegistry), read once at init.
//
// Table mapping (verified on Mac17,12 / M5 Pro):
//   voltage-states5   (20 entries) -> Super cluster      (IOReport PCPUn: 22 states = DOWN, IDLE, V0P19..V19P0)
//   voltage-states22  (15 entries) -> Performance cluster 1 (MCPU0n: 17 states = DOWN, IDLE, V0P14..V14P0)
//   voltage-states23  (15 entries) -> Performance cluster 2 (MCPU1n), identical to 22
//   voltage-states31  (13 entries, Hz) -> GPU P1..P13 (GPUPH: OFF, P1..P15; indices past the table clamp)
// Tables are matched generically by V-state count of the IOReport channel, not by hard-coded key.
// On M5 the CPU tables hold period-like values (50103..14222) but a sibling "voltage-statesN-sram" table holds
// the same points in kHz (1308000..4608000), which is used when present. Fallback: MHz = 6.556e7 / value.
// Values > 1e8 are treated as Hz.
import Foundation
import IOKit

struct FrequencyTables {
    /// key -> MHz per V-state index
    private(set) var tables: [String: [Double]] = [:]

    init() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            for (k, v) in dict where k.hasPrefix("voltage-states") && !k.hasSuffix("-sram") {
                guard let data = v as? Data, data.count >= 8, data.count % 8 == 0 else { continue }
                let raw = Self.firstColumn(data)
                var mhz: [Double]
                if let sram = dict[k + "-sram"] as? Data, sram.count == data.count {
                    mhz = Self.firstColumn(sram).map { $0 / 1000.0 }   // kHz
                } else {
                    mhz = raw.map { $0 > 1e8 ? $0 / 1e6 : ($0 > 1 ? 6.556e7 / $0 : 0) }
                }
                if mhz.contains(where: { $0 > 0 }) && !(raw.allSatisfy { $0 <= 1 }) { tables[k] = mhz }
            }
        }
    }

    private static func firstColumn(_ d: Data) -> [Double] {
        var out: [Double] = []
        let n = d.count / 8
        d.withUnsafeBytes { p in
            for i in 0..<n { out.append(Double(p.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self))) }
        }
        return out
    }

    /// Table (MHz, ascending state order) with exactly `count` entries, preferring CPU-style tables (< 6 GHz).
    func cpuTable(count: Int) -> [Double]? {
        tables.keys.sorted { (Int($0.dropFirst(14)) ?? 0) < (Int($1.dropFirst(14)) ?? 0) }
            .compactMap { tables[$0] }
            .first { $0.count == count && ($0.max() ?? 0) > 1500 && ($0.min() ?? 0) > 500 && ($0.max() ?? 0) < 6000 }
    }

    /// GPU table: voltage-states31 if present, else first Hz-based table with leading zero stripped.
    func gpuTable() -> [Double]? {
        if let t = tables["voltage-states31"] { return t }
        for k in tables.keys.sorted() {
            var t = tables[k]!
            if t.first == 0 { t.removeFirst() }
            if t.count >= 8, (t.min() ?? 0) > 100, (t.max() ?? 0) < 3000 { return t }
        }
        return nil
    }
}

enum FrequencyMath {
    /// Weighted-average MHz over active states of a CPU performance-state channel ("V<i>P<j>").
    static func cpuActive(_ states: [(name: String, residency: Int64)], table: [Double]?) -> (mhz: Double, weight: Double)? {
        guard let table, !table.isEmpty else { return nil }
        var sum = 0.0, w = 0.0
        for s in states where s.residency > 0 && s.name.hasPrefix("V") {
            let digits = s.name.dropFirst().prefix { $0.isNumber }
            guard let i = Int(digits) else { continue }
            let f = table[min(max(i, 0), table.count - 1)]
            sum += f * Double(s.residency); w += Double(s.residency)
        }
        return w > 0 ? (sum / w, w) : nil
    }

    /// GPU "P<n>" states, P1 = first table entry, clamped.
    static func gpuActive(_ states: [(name: String, residency: Int64)], table: [Double]?) -> Double? {
        guard let table, !table.isEmpty else { return nil }
        var sum = 0.0, w = 0.0
        for s in states where s.residency > 0 && s.name.hasPrefix("P") {
            guard let n = Int(s.name.dropFirst()) else { continue }
            let f = table[min(max(n - 1, 0), table.count - 1)]
            sum += f * Double(s.residency); w += Double(s.residency)
        }
        return w > 0 ? sum / w : nil
    }
}
