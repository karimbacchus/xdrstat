import Foundation
@_silgen_name("IOReportCopyChannelsInGroup") func IOReportCopyChannelsInGroup(_ g: CFString?, _ s: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSubscription") func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ d: CFMutableDictionary, _ o: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ id: UInt64, _ x: CFTypeRef?) -> OpaquePointer?
@_silgen_name("IOReportCreateSamples") func IOReportCreateSamples(_ s: OpaquePointer, _ d: CFMutableDictionary, _ x: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta") func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ x: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetGroup") func IOReportChannelGetGroup(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetSubGroup") func IOReportChannelGetSubGroup(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetChannelName") func IOReportChannelGetChannelName(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue") func IOReportSimpleGetIntegerValue(_ c: CFDictionary, _ i: Int32) -> Int64
@_silgen_name("IOReportChannelGetUnitLabel") func IOReportChannelGetUnitLabel(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetCount") func IOReportStateGetCount(_ c: CFDictionary) -> Int32
@_silgen_name("IOReportStateGetNameForIndex") func IOReportStateGetNameForIndex(_ c: CFDictionary, _ i: Int32) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetResidency") func IOReportStateGetResidency(_ c: CFDictionary, _ i: Int32) -> Int64
let e = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0,0,0)!.takeRetainedValue()
let c = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0,0,0)!.takeRetainedValue()
let g = IOReportCopyChannelsInGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0,0,0)!.takeRetainedValue()
let m = NSMutableDictionary(dictionary: e as NSDictionary)
for d in [c, g] { (m["IOReportChannels"] as! NSMutableArray).addObjects(from: ((d as NSDictionary)["IOReportChannels"] as! [Any])) }
var subd: Unmanaged<CFMutableDictionary>?
let sub = IOReportCreateSubscription(nil, m as! CFMutableDictionary, &subd, 0, nil)!
let s1 = IOReportCreateSamples(sub, subd!.takeUnretainedValue(), nil)!.takeRetainedValue()
Thread.sleep(forTimeInterval: 1)
let s2 = IOReportCreateSamples(sub, subd!.takeUnretainedValue(), nil)!.takeRetainedValue()
let d = IOReportCreateSamplesDelta(s1, s2, nil)!.takeRetainedValue() as NSDictionary
for ch in d["IOReportChannels"] as! [CFDictionary] {
  let grp = IOReportChannelGetGroup(ch)?.takeUnretainedValue() as String? ?? ""
  let name = IOReportChannelGetChannelName(ch)?.takeUnretainedValue() as String? ?? ""
  if grp == "Energy Model" { let v = IOReportSimpleGetIntegerValue(ch, 0); if v > 0 { print("E", name, v, IOReportChannelGetUnitLabel(ch)?.takeUnretainedValue() as String? ?? "") } }
  else { let n = IOReportStateGetCount(ch); var parts: [String] = []
    for i in 0..<n { let r = IOReportStateGetResidency(ch, i); if r > 0 { parts.append("\(IOReportStateGetNameForIndex(ch,i)!.takeUnretainedValue()):\(r)") } }
    print(grp.prefix(3), name, n, parts.prefix(6).joined(separator: " ")) }
}
