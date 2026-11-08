import Foundation
import IOKit
import IOKit.hidsystem
@_silgen_name("IOHIDEventSystemClientCreate") func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") func IOHIDEventSystemClientSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") func IOHIDEventSystemClientCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") func IOHIDServiceClientCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") func IOHIDServiceClientCopyEvent(_ s: AnyObject, _ t: Int64, _ a: Int32, _ b: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func IOHIDEventGetFloatValue(_ e: AnyObject, _ f: Int32) -> Double
let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault)!.takeRetainedValue()
_ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
let svcs = IOHIDEventSystemClientCopyServices(c)!.takeRetainedValue() as! [AnyObject]
for s in svcs {
  let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
  if let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue() {
    print(name, String(format: "%.1f", IOHIDEventGetFloatValue(e, 15 << 16)))
  }
}
