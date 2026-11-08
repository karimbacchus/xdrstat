// Reusable AppleSMC client (unprivileged). Not thread-safe: use from a single queue.
import Foundation
import IOKit

/// Mirror of the kernel's 80-byte SMCParamStruct. The 3 trailing pad bytes in `keyInfo` matter.
private struct SMCParam {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo: (UInt32, UInt32, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0) // size, type, attr, pad
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0) // 32 bytes
}

struct SMCKeyInfo {
    var size: UInt32
    var type: UInt32
    var typeString: String { SMCClient.string(from: type) }
}

final class SMCClient {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]
    private var input = SMCParam()
    private var output = SMCParam()

    /// nil if AppleSMC cannot be opened.
    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else { return nil }
        assert(MemoryLayout<SMCParam>.stride == 80)
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // MARK: 4CC helpers
    static func code(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    static func string(from v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }

    private func call(_ i: inout SMCParam, _ o: inout SMCParam) -> Bool {
        var outSize = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<SMCParam>.stride, &o, &outSize)
        return r == KERN_SUCCESS && o.result == 0
    }

    // MARK: Enumeration / info
    var keyCount: Int {
        var i = SMCParam(); i.key = Self.code("#KEY"); i.data8 = 5; i.keyInfo.0 = 4
        var o = SMCParam()
        guard call(&i, &o) else { return 0 }
        return withUnsafeBytes(of: o.bytes) { Int(UInt32($0[0]) << 24 | UInt32($0[1]) << 16 | UInt32($0[2]) << 8 | UInt32($0[3])) }
    }

    func key(at index: Int) -> UInt32? {
        var i = SMCParam(); i.data8 = 8; i.data32 = UInt32(index)
        var o = SMCParam()
        guard call(&i, &o), o.key != 0 else { return nil }
        return o.key
    }

    func info(for key: UInt32) -> SMCKeyInfo? {
        if let c = infoCache[key] { return c }
        var i = SMCParam(); i.key = key; i.data8 = 9
        var o = SMCParam()
        guard call(&i, &o), o.keyInfo.0 > 0, o.keyInfo.0 <= 32 else { return nil }
        let k = SMCKeyInfo(size: o.keyInfo.0, type: o.keyInfo.1)
        infoCache[key] = k
        return k
    }

    // MARK: Reading
    /// Raw read with known info: exactly one SMC call.
    fileprivate func readRaw(_ key: UInt32, info: SMCKeyInfo) -> SMCParam? {
        input = SMCParam(); input.key = key; input.data8 = 5; input.keyInfo.0 = info.size
        output = SMCParam()
        guard call(&input, &output) else { return nil }
        return output
    }

    /// Reads a numeric key (cached info) and decodes it to Double. nil for non-numeric/failed.
    func readValue(_ key: UInt32) -> Double? {
        guard let info = info(for: key), let p = readRaw(key, info: info) else { return nil }
        return withUnsafeBytes(of: p.bytes) { Self.decode(type: info.type, size: Int(info.size), bytes: $0) }
    }

    func readValue(_ key: String) -> Double? { readValue(Self.code(key)) }

    static let numericTypes: Set<UInt32> = Set(
        ["flt ", "ui8 ", "ui16", "ui32", "ui64", "si8 ", "si16", "si32", "si64", "fpe2", "sp78", "ioft", "flag"].map(code))
    static let floatTypes: Set<UInt32> = Set(["flt ", "fpe2", "sp78", "ioft"].map(code))

    static func decode(type: UInt32, size: Int, bytes b: UnsafeRawBufferPointer) -> Double? {
        guard size >= 1, size <= b.count else { return nil }
        func be(_ n: Int) -> UInt64 { var v: UInt64 = 0; for k in 0..<n { v = v << 8 | UInt64(b[k]) }; return v }
        switch string(from: type) {
        case "flt ": guard size == 4 else { return nil }; return Double(b.loadUnaligned(as: Float.self))   // little-endian
        case "ioft": guard size == 8 else { return nil }; return Double(b.loadUnaligned(as: UInt64.self)) / 65536.0
        case "ui8 ", "flag": return Double(b[0])
        case "ui16": guard size == 2 else { return nil }; return Double(be(2))
        case "ui32": guard size == 4 else { return nil }; return Double(be(4))
        case "ui64": guard size == 8 else { return nil }; return Double(be(8))
        case "si8 ": return Double(Int8(bitPattern: b[0]))
        case "si16": guard size == 2 else { return nil }; return Double(Int16(truncatingIfNeeded: be(2)))
        case "si32": guard size == 4 else { return nil }; return Double(Int32(truncatingIfNeeded: be(4)))
        case "si64": guard size == 8 else { return nil }; return Double(Int64(bitPattern: be(8)))
        case "fpe2": guard size == 2 else { return nil }; return Double(be(2)) / 4.0
        case "sp78": guard size == 2 else { return nil }; return Double(Int16(truncatingIfNeeded: be(2))) / 256.0
        default: return nil
        }
    }
}

extension SMCClient {
    /// All key codes (index enumeration). ~4k calls; do once.
    func allKeys() -> [UInt32] {
        let n = keyCount
        var out: [UInt32] = []
        out.reserveCapacity(n)
        for idx in 0..<n { if let k = key(at: idx) { out.append(k) } }
        return out
    }
}
