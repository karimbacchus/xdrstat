// IOReport (private, libIOReport) bindings and a delta-sampling subscription wrapper.
import Foundation

@_silgen_name("IOReportCopyChannelsInGroup") func IOReportCopyChannelsInGroup(_ g: CFString?, _ s: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSubscription") func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ d: CFMutableDictionary, _ o: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ id: UInt64, _ x: CFTypeRef?) -> OpaquePointer?
@_silgen_name("IOReportCreateSamples") func IOReportCreateSamples(_ s: OpaquePointer, _ d: CFMutableDictionary?, _ x: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta") func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ x: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetGroup") func IOReportChannelGetGroup(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetSubGroup") func IOReportChannelGetSubGroup(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetChannelName") func IOReportChannelGetChannelName(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue") func IOReportSimpleGetIntegerValue(_ c: CFDictionary, _ i: Int32) -> Int64
@_silgen_name("IOReportChannelGetUnitLabel") func IOReportChannelGetUnitLabel(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetCount") func IOReportStateGetCount(_ c: CFDictionary) -> Int32
@_silgen_name("IOReportStateGetNameForIndex") func IOReportStateGetNameForIndex(_ c: CFDictionary, _ i: Int32) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetResidency") func IOReportStateGetResidency(_ c: CFDictionary, _ i: Int32) -> Int64

/// One channel of a delta sample, copied into plain Swift values.
struct IORChannel {
    var group: String
    var subgroup: String
    var name: String
    var unit: String
    var value: Int64                       // simple channels
    var states: [(name: String, residency: Int64)]   // state channels
}

struct IORDelta {
    var channels: [IORChannel]
    var elapsed: Double                    // seconds between the two samples (real timestamps)
}

final class IOReportSession {
    private var sub: OpaquePointer?
    private var subbed: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: UInt64 = 0
    private let tb: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    init?() {
        guard let e = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        let merged = NSMutableDictionary(dictionary: e as NSDictionary)
        guard let arr = merged["IOReportChannels"] as? NSArray else { return nil }
        let all = NSMutableArray(array: arr)
        let extra: [(String, String)] = [("CPU Stats", "CPU Core Performance States"), ("GPU Stats", "GPU Performance States")]
        for (g, s) in extra {
            if let d = IOReportCopyChannelsInGroup(g as CFString, s as CFString, 0, 0, 0)?.takeRetainedValue() as NSDictionary?,
               let a = d["IOReportChannels"] as? [Any] { all.addObjects(from: a) }
        }
        merged["IOReportChannels"] = all
        var out: Unmanaged<CFMutableDictionary>?
        guard let s = IOReportCreateSubscription(nil, merged as CFMutableDictionary, &out, 0, nil), let o = out else { return nil }
        sub = s
        subbed = o.takeRetainedValue()   // Create rule: we own it; kept for the lifetime of the session
    }

    private func now() -> UInt64 { mach_continuous_time() }

    /// Takes a sample and returns the delta since the previous call (nil on the first call).
    func sampleDelta() -> IORDelta? {
        guard let sub, let subbed else { return nil }
        return autoreleasepool { () -> IORDelta? in
            guard let cur = IOReportCreateSamples(sub, subbed, nil)?.takeRetainedValue() else { return nil }
            let t = now()
            defer { previous = cur; previousTime = t }
            guard let prev = previous else { return nil }
            guard let d = IOReportCreateSamplesDelta(prev, cur, nil)?.takeRetainedValue() else { return nil }
            let ticks = t &- previousTime
            let secs = Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1e9
            guard let chans = (d as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
            var out: [IORChannel] = []
            out.reserveCapacity(chans.count)
            for ch in chans {
                let grp = IOReportChannelGetGroup(ch)?.takeUnretainedValue() as String? ?? ""
                let sg = IOReportChannelGetSubGroup(ch)?.takeUnretainedValue() as String? ?? ""
                let name = IOReportChannelGetChannelName(ch)?.takeUnretainedValue() as String? ?? ""
                if grp == "Energy Model" {
                    out.append(IORChannel(group: grp, subgroup: sg, name: name,
                                          unit: IOReportChannelGetUnitLabel(ch)?.takeUnretainedValue() as String? ?? "",
                                          value: IOReportSimpleGetIntegerValue(ch, 0), states: []))
                } else {
                    let n = IOReportStateGetCount(ch)
                    var st: [(String, Int64)] = []
                    st.reserveCapacity(Int(n))
                    for i in 0..<n {
                        st.append((IOReportStateGetNameForIndex(ch, i)?.takeUnretainedValue() as String? ?? "", IOReportStateGetResidency(ch, i)))
                    }
                    out.append(IORChannel(group: grp, subgroup: sg, name: name, unit: "", value: 0, states: st))
                }
            }
            return IORDelta(channels: out, elapsed: max(secs, 0.001))
        }
    }

    /// Joules for an Energy Model channel, honoring its unit label.
    static func joules(_ c: IORChannel) -> Double {
        let v = Double(c.value)
        switch c.unit.lowercased() {
        case "mj": return v / 1e3
        case "uj", "µj": return v / 1e6
        case "nj": return v / 1e9
        case "j": return v
        default: return v / 1e3
        }
    }
}
