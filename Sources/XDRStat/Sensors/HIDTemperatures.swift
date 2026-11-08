// Fallback temperature source (IOHIDEventSystemClient) used only if AppleSMC cannot be opened.
import Foundation
import IOKit

@_silgen_name("IOHIDEventSystemClientCreate")
private func _hidClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func _hidSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func _hidCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func _hidCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func _hidCopyEvent(_ s: AnyObject, _ t: Int64, _ a: Int32, _ b: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func _hidFloat(_ e: AnyObject, _ f: Int32) -> Double

final class HIDTemperatures {
    private var client: AnyObject?
    private var services: [(name: String, service: AnyObject)] = []

    init?() {
        guard let c = _hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = _hidSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let arr = _hidCopyServices(c)?.takeRetainedValue() as? [AnyObject] else { return nil }
        client = c
        for s in arr {
            let name = (_hidCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "HID Sensor"
            services.append((name, s))
        }
        if services.isEmpty { return nil }
    }

    /// Valid temperature sensors, with duplicate product names disambiguated.
    func read() -> (sensors: [Sensor], cpuAverage: Double?) {
        var seen: [String: Int] = [:]
        var out: [Sensor] = []
        var dies: [Double] = []
        for (name, s) in services {
            guard let ev = _hidCopyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = _hidFloat(ev, 15 << 16)
            guard SensorCatalog.validTemp(v) else { continue }     // drops "tdev" garbage (-9200)
            let n = (seen[name] ?? 0) + 1
            seen[name] = n
            let group: SensorGroup = name.contains("NAND") ? .storage : name.contains("battery") ? .battery : .soc
            let friendly = n > 1 || services.filter({ $0.name == name }).count > 1 ? "\(name) \(n)" : name
            out.append(Sensor(id: "hid.\(name).\(n)", name: friendly, group: group, value: v, unit: .celsius))
            if name.contains("tdie") { dies.append(v) }
        }
        return (out, dies.isEmpty ? nil : dies.reduce(0, +) / Double(dies.count))
    }
}
