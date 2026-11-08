import Foundation
import IOKit
struct KeyData { var key: UInt32 = 0; var vers = (UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt16(0)); var pLimit = (UInt16(0),UInt16(0),UInt32(0),UInt32(0),UInt32(0))
  var keyInfo = (UInt32(0), UInt32(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)); var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0; var data32: UInt32 = 0
  var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) }
print(MemoryLayout<KeyData>.size)
var conn: io_connect_t = 0
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
IOServiceOpen(svc, mach_task_self_, 0, &conn)
func call(_ i: inout KeyData) -> KeyData { var o = KeyData(); var sz = MemoryLayout<KeyData>.stride
  IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<KeyData>.stride, &o, &sz); return o }
func fcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func str(_ v: UInt32) -> String { String(bytes: [24,16,8,0].map{ UInt8((v >> UInt32($0)) & 0xff) }, encoding: .ascii)! }
func read(_ key: UInt32) -> (String, [UInt8])? {
  var i = KeyData(); i.key = key; i.data8 = 9; let info = call(&i); if info.result != 0 { return nil }
  var r = KeyData(); r.key = key; r.keyInfo.0 = info.keyInfo.0; r.data8 = 5; let o = call(&r); if o.result != 0 { return nil }
  let b = withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(info.keyInfo.0))) }
  return (str(info.keyInfo.1), b) }
var cnt = KeyData(); cnt.key = fcc("#KEY"); cnt.data8 = 5; cnt.keyInfo.0 = 4
let n = withUnsafeBytes(of: call(&cnt).bytes) { UInt32($0[0])<<24|UInt32($0[1])<<16|UInt32($0[2])<<8|UInt32($0[3]) }
print("keys", n)
for idx in 0..<n { var k = KeyData(); k.data8 = 8; k.data32 = idx; let key = call(&k).key
  let ks = str(key); guard let f = ks.first, "TFPVIDB".contains(f) else { continue }
  guard let (t, b) = read(key) else { continue }
  var v = ""
  if t.hasPrefix("flt") && b.count == 4 { v = String(format: "%.2f", b.withUnsafeBytes { $0.load(as: Float.self) }) }
  else if t == "ui8 " { v = "\(b[0])" } else if t == "ui16" { v = "\(UInt16(b[0])<<8|UInt16(b[1]))" }
  else { v = b.map{String(format:"%02x",$0)}.joined() }
  print(ks, t, v) }
