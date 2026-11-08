// IOAccelerator PerformanceStatistics + static GPU info.
import Foundation
import IOKit

final class GPUInfoReader {
    private let service: io_service_t
    let model: String?
    let coreCount: Int

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        func prop(_ k: String) -> Any? {
            guard svc != 0 else { return nil }
            return IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        service = svc
        if let d = prop("model") as? Data { model = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self) }
        else { model = prop("model") as? String }
        coreCount = (prop("gpu-core-count") as? NSNumber)?.intValue ?? 0
    }

    deinit { if service != 0 { IOObjectRelease(service) } }

    struct Stats { var device = 0.0, renderer = 0.0, tiler = 0.0; var inUse: UInt64 = 0, alloc: UInt64 = 0 }

    func stats() -> Stats {
        var s = Stats()
        guard service != 0,
              let v = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let d = v as? [String: Any] else { return s }
        func n(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        s.device = min(1, n("Device Utilization %") / 100)
        s.renderer = min(1, n("Renderer Utilization %") / 100)
        s.tiler = min(1, n("Tiler Utilization %") / 100)
        s.inUse = UInt64(max(0, n("In use system memory")))
        s.alloc = UInt64(max(0, n("Alloc system memory")))
        return s
    }
}
