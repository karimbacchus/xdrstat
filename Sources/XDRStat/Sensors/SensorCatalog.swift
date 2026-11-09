// Maps raw SMC keys to friendly names / groups and builds the per-machine sensor tables.
import Foundation

struct SensorDef {
    var key: UInt32
    var keyString: String
    var id: String
    var name: String
    var group: SensorGroup
    var unit: SensorUnit
    var info: SMCKeyInfo
    /// Read while the Sensors panel is closed (menu bar headline). Others only when detailed or pinned.
    var essential: Bool
    /// Has a friendly name (sorted first in its section).
    var named = false
    var role: Role
    enum Role { case plain, cpuDie, gpuDie, memDie }
}

struct FanDef {
    var index: Int
    var name: String
    var ac: UInt32, mn: UInt32, mx: UInt32, tg: UInt32
}

enum SensorCatalog {
    // MARK: - Temperature classification

    private struct Rule {
        var group: SensorGroup
        var base: String        // name; numbered " n" suffix appended when `numbered`
        var numbered: Bool
        var rank: Int           // ordering of families within a group
        var role: SensorDef.Role = .plain
        var essential = false
    }

    private static let fixedTemps: [String: (SensorGroup, String)] = [
        "TaLP": (.enclosure, "Left Airflow"),
        "TaLT": (.enclosure, "Left Enclosure (T)"),
        "TaLW": (.enclosure, "Left Enclosure (W)"),
        "TaRF": (.enclosure, "Right Airflow"),
        "TaRT": (.enclosure, "Right Enclosure (T)"),
        "TaRW": (.enclosure, "Right Enclosure (W)"),
        "TaTP": (.enclosure, "Top Airflow"),
        "TH0x": (.storage, "SSD (max)"),
        "TW0P": (.wireless, "Wi\u{2011}Fi / Bluetooth"),
        "TCHP": (.power, "Charger"),
        "TJUN": (.soc, "Junction"),
        "TDTC": (.display, "Display Driver TC"),
        "TDTP": (.display, "Display Driver TP"),
        "TDVx": (.display, "Display Driver (max)"),
    ]

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    private static func classifyTemp(_ k: String) -> Rule {
        let u = Array(k.utf8)
        guard u.count == 4 else { return Rule(group: .other, base: "Sensor \(k)", numbered: false, rank: 99) }
        if let (g, n) = fixedTemps[k] { return Rule(group: g, base: n, numbered: false, rank: 10) }
        let c1 = u[1], c2 = u[2], c3 = u[3]
        switch k.prefix(2) {
        case "Ts":
            if k == "Ts0P" || k == "Ts1P" { return Rule(group: .enclosure, base: "Chassis", numbered: true, rank: 20) }
            return Rule(group: .cpu, base: "CPU Super Cluster", numbered: true, rank: 1, role: .cpuDie, essential: true)
        case "Tp": return Rule(group: .cpu, base: "CPU Performance", numbered: true, rank: 2, role: .cpuDie, essential: true)
        case "Tg": return Rule(group: .gpu, base: "GPU", numbered: true, rank: 1, role: .gpuDie, essential: true)
        case "Tm": return Rule(group: .memory, base: "Memory", numbered: true, rank: 1, role: .memDie)
        case "Ta" where isDigit(c2): return Rule(group: .soc, base: "SoC", numbered: true, rank: 1)
        case "TA" where c2 == 79 /* O */: return Rule(group: .enclosure, base: "Ambient Inlet", numbered: true, rank: 1)
        case "TB" where c3 == 84 /* T */: return Rule(group: .battery, base: "Battery", numbered: true, rank: 1)
        case "TH": return Rule(group: .storage, base: "SSD", numbered: true, rank: 1)
        case "TN" where isDigit(c2) && isDigit(c3): return Rule(group: .storage, base: "NAND Channel", numbered: true, rank: 2)
        case "Tf" where c2 == 67 /* C */: return Rule(group: .soc, base: "Fabric", numbered: true, rank: 2)
        default: break
        }
        if k.hasPrefix("TD") {
            if isDigit(c2) && isDigit(c3) { return Rule(group: .display, base: "Display Panel", numbered: true, rank: 1) }
            return Rule(group: .display, base: "Display Driver", numbered: true, rank: 2)
        }
        if (k.hasPrefix("TPD") || k.hasPrefix("TRD") || k.hasPrefix("TUD")) {
            let die = String(UnicodeScalar(c1))
            if c3 == 88 /* X */ { return Rule(group: .power, base: "PMU Die \(die) (max)", numbered: false, rank: 5) }
            return Rule(group: .power, base: "PMU Die \(die)", numbered: true, rank: die == "P" ? 1 : die == "R" ? 2 : 3)
        }
        if k.hasPrefix("TV") { return Rule(group: .power, base: "VRM \(k)", numbered: false, rank: 8) }
        return Rule(group: .other, base: "Sensor \(k)", numbered: false, rank: 99)
    }

    // MARK: - Build tables

    struct Tables {
        var temps: [SensorDef] = []       // sorted: group order, rank, key
        var power: [SensorDef] = []
        var volts: [SensorDef] = []
        var amps: [SensorDef] = []
        var fans: [FanDef] = []
    }

    private static let powerNames: [String: (String, SensorGroup)] = [
        "PSTR": ("System Total", .power),
        "PPBR": ("Battery Rail", .power),
    ]
    private static let voltNames: [String: (String, SensorGroup)] = [
        "VD0C": ("DC In", .power), "Vb0f": ("Battery", .battery),
    ]
    private static let ampNames: [String: (String, SensorGroup)] = [
        "Ib0f": ("Battery", .battery),
    ]
    /// Thresholds / limits that are not measurements.
    private static let powerBlacklist: Set<String> = ["PHPB", "PZT0"]

    static func build(smc: SMCClient) -> Tables {
        var t = Tables()
        var tempRaw: [(String, UInt32, SMCKeyInfo, Rule)] = []
        var fanCount = 0
        for key in smc.allKeys() {
            let ks = SMCClient.string(from: key)
            guard let first = ks.utf8.first else { continue }
            switch first {
            case UInt8(ascii: "T"), UInt8(ascii: "P"), UInt8(ascii: "V"), UInt8(ascii: "I"):
                guard let info = smc.info(for: key), SMCClient.floatTypes.contains(info.type) else { continue }
                switch first {
                case UInt8(ascii: "T"): tempRaw.append((ks, key, info, classifyTemp(ks)))
                case UInt8(ascii: "P"):
                    if powerBlacklist.contains(ks) { continue }
                    let (n, g) = powerNames[ks] ?? ("Rail \(ks)", .power)
                    // Only System Total feeds the closed-panel state (the power history).
                    var d = def(key, ks, n, g, .watts, info, essential: ks == "PSTR")
                    d.named = powerNames[ks] != nil
                    t.power.append(d)
                case UInt8(ascii: "V"):
                    let (n, g) = voltNames[ks] ?? ("Voltage \(ks)", .power)
                    var d = def(key, ks, n, g, .volts, info, essential: false)
                    d.named = voltNames[ks] != nil
                    t.volts.append(d)
                default:
                    let (n, g) = ampNames[ks] ?? ("Current \(ks)", .power)
                    var d = def(key, ks, n, g, .amps, info, essential: false)
                    d.named = ampNames[ks] != nil
                    t.amps.append(d)
                }
            case UInt8(ascii: "F"):
                if ks == "FNum", let v = smc.readValue(key) { fanCount = Int(v) }
            default: break
            }
        }
        // Temperatures: order by group, rank, key; number within each (group, base) family.
        let groupIndex = Dictionary(uniqueKeysWithValues: SensorGroup.allCases.enumerated().map { ($1, $0) })
        tempRaw.sort {
            let a = ($0.3, $1.3)
            if a.0.group != a.1.group { return groupIndex[a.0.group]! < groupIndex[a.1.group]! }
            if a.0.rank != a.1.rank { return a.0.rank < a.1.rank }
            return $0.0 < $1.0
        }
        var counters: [String: Int] = [:]
        var gpuSeen = 0
        for (ks, key, info, rule) in tempRaw {
            var name = rule.base
            if rule.numbered {
                let n = (counters["\(rule.group.rawValue)|\(rule.base)"] ?? 0) + 1
                counters["\(rule.group.rawValue)|\(rule.base)"] = n
                name += " \(n)"
            }
            var d = def(key, ks, name, rule.group, .celsius, info, essential: rule.essential)
            if rule.role == .gpuDie {
                // Compact (non-detailed) ticks sample only every 5th GPU die for the headline average.
                gpuSeen += 1
                d.essential = (gpuSeen - 1) % 5 == 0
            }
            d.role = rule.role
            t.temps.append(d)
        }
        t.power.sort { $0.keyString < $1.keyString }
        t.volts.sort { $0.keyString < $1.keyString }
        t.amps.sort { $0.keyString < $1.keyString }
        // Named ones first.
        func named(_ a: SensorDef, _ b: SensorDef) -> Bool {
            if a.named != b.named { return a.named }
            if a.keyString == "PSTR" || b.keyString == "PSTR" { return a.keyString == "PSTR" }
            return a.keyString < b.keyString
        }
        t.power.sort(by: named); t.volts.sort(by: named); t.amps.sort(by: named)

        // Fans
        for n in 0..<max(0, min(fanCount, 8)) {
            let p = "F\(n)"
            let ac = SMCClient.code(p + "Ac")
            guard smc.info(for: ac) != nil else { continue }
            let name = fanCount == 2 ? (n == 0 ? "Left Fan" : "Right Fan") : "Fan \(n + 1)"
            t.fans.append(FanDef(index: n, name: name, ac: ac, mn: SMCClient.code(p + "Mn"),
                                 mx: SMCClient.code(p + "Mx"), tg: SMCClient.code(p + "Tg")))
        }
        return t
    }

    private static func def(_ key: UInt32, _ ks: String, _ name: String, _ g: SensorGroup, _ u: SensorUnit,
                            _ info: SMCKeyInfo, essential: Bool) -> SensorDef {
        SensorDef(key: key, keyString: ks, id: ks, name: name, group: g, unit: u, info: info,
                  essential: essential, role: .plain)
    }

    // MARK: - Validity

    static func validTemp(_ v: Double) -> Bool { v.isFinite && v > 0 && v < 130 }
    static func validValue(_ v: Double, unit: SensorUnit) -> Bool {
        guard v.isFinite else { return false }
        switch unit {
        case .watts: return v >= 0 && v < 500
        case .volts: return v >= 0 && v < 100
        case .amps: return abs(v) < 100
        default: return true
        }
    }
}
