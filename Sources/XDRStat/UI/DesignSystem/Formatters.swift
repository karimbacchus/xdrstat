import Foundation

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        var v = Double(b)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(b) B" }
        return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    static func rate(_ bps: Double) -> String {
        let v = max(0, bps)
        if v < 1 { return "0 B/s" }
        return bytes(UInt64(v)) + "/s"
    }

    /// Number and unit split for display with a smaller unit ("64", "KB/s").
    static func bytesParts(_ b: UInt64) -> (String, String) {
        var v = Double(b)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return ("\(b)", "B") }
        return (String(format: v >= 100 ? "%.0f" : "%.1f", v), units[i])
    }
    static func rateParts(_ bps: Double) -> (String, String) {
        let p = bytesParts(UInt64(max(0, bps)))
        return (p.0, p.1 + "/s")
    }
    static func freqParts(_ mhz: Double) -> (String, String) {
        mhz >= 1000 ? (String(format: "%.2f", mhz / 1000), "GHz") : (String(format: "%.0f", mhz), "MHz")
    }
    static func uptimeLong(_ t: TimeInterval) -> String {
        let s = Int(t), d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        func u(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        if d > 0 { return "\(u(d, "day")), \(u(h, "hour"))" }
        if h > 0 { return "\(u(h, "hour")), \(u(m, "minute"))" }
        return u(m, "minute")
    }

    static func percent(_ f: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", f * 100)
    }

    static func temp(_ c: Double, _ unit: TemperatureUnit, suffix: Bool = false) -> String {
        let v = unit == .celsius ? c : c * 9 / 5 + 32
        return String(format: "%.0f°", v) + (suffix ? (unit == .celsius ? "C" : "F") : "")
    }

    static func freq(_ mhz: Double, estimated: Bool = false) -> String {
        let p = estimated ? "~" : ""
        return mhz >= 1000 ? String(format: "\(p)%.2f GHz", mhz / 1000) : String(format: "\(p)%.0f MHz", mhz)
    }

    static func watts(_ w: Double) -> String {
        abs(w) < 10 ? String(format: "%.2f W", w) : String(format: "%.1f W", w)
    }

    static func wattsParts(_ w: Double) -> (String, String) {
        (abs(w) < 10 ? String(format: "%.2f", w) : String(format: "%.1f", w), "W")
    }

    static func uptime(_ t: TimeInterval) -> String {
        let s = Int(t), d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }

    static func rpm(_ r: Double) -> String {
        if r < 1 { return "Off" }   // Fans park at 0 rpm when the system is cool.
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: r)) ?? "\(Int(r))") + " rpm"
    }

    static func sensor(_ s: Sensor, unit: TemperatureUnit) -> String {
        switch s.unit {
        case .celsius: return temp(s.value, unit, suffix: true)
        case .rpm: return rpm(s.value)
        case .watts: return watts(s.value)
        case .volts: return String(format: "%.3f V", s.value)
        case .amps: return String(format: "%.3f A", s.value)
        case .percent: return String(format: "%.0f%%", s.value)
        }
    }

    /// Nice axis maximum in binary units (so labels read "2 MB/s", not "1.9").
    static func niceRate(_ v: Double) -> Double {
        var unit = 1.0
        while v / unit >= 1000 { unit *= 1024 }
        return niceMax(v / unit) * unit
    }

    /// Round up to 1/2/5 × 10^n.
    static func niceMax(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let e = pow(10, floor(log10(v)))
        let f = v / e
        let n: Double = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10
        return n * e
    }
}
