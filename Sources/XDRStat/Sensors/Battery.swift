// AppleSmartBattery reader (IOKit registry). Single-queue use.
import Foundation
import IOKit

final class BatteryReader {
    private var service: io_service_t = 0

    deinit { if service != 0 { IOObjectRelease(service) } }

    private func ensureService() -> Bool {
        if service != 0 { return true }
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        return service != 0
    }

    struct Result {
        var battery = BatterySnapshot()
        /// Power drawn from the adapter in watts (PowerTelemetryData.SystemPowerIn), if reported.
        var adapterInputW: Double?
        /// True if the registry exposed its own Temperature property.
        var hasTemperature = false
    }

    private static func int(_ d: [String: Any]?, _ k: String) -> Int? { (d?[k] as? NSNumber)?.intValue }
    private static func signed64(_ d: [String: Any]?, _ k: String) -> Int64? {
        guard let n = d?[k] as? NSNumber else { return nil }
        return Int64(bitPattern: n.uint64Value)   // Amperage etc. are signed values stored as UInt64
    }

    func read() -> Result {
        var r = Result()
        guard ensureService() else { return r }
        var cf: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = cf?.takeRetainedValue() as? [String: Any] else {
            // Service went stale; re-acquire next time.
            IOObjectRelease(service); service = 0
            return r
        }
        var b = BatterySnapshot()
        b.present = (props["BatteryInstalled"] as? Bool) ?? true
        let bd = props["BatteryData"] as? [String: Any]

        let cur = Self.int(props, "CurrentCapacity") ?? 0
        let maxC = Self.int(props, "MaxCapacity") ?? 100
        b.percent = maxC > 0 ? max(0, min(1, Double(cur) / Double(maxC))) : 0
        b.isCharging = (props["IsCharging"] as? Bool) ?? false
        b.isPluggedIn = (props["ExternalConnected"] as? Bool) ?? false
        b.isFullyCharged = (props["FullyCharged"] as? Bool) ?? false
        b.cycleCount = Self.int(props, "CycleCount") ?? 0

        b.designCapacitymAh = Self.int(props, "DesignCapacity") ?? Self.int(bd, "DesignCapacity") ?? 0
        let full = Self.int(bd, "FullChargeCapacity") ?? Self.int(props, "AppleRawMaxCapacity") ?? 0
        b.fullChargeCapacitymAh = full
        if b.designCapacitymAh > 0, full > 0 { b.healthFraction = min(1, Double(full) / Double(b.designCapacitymAh)) }

        if let t = Self.int(props, "Temperature") {
            let c = Double(t) / 100.0           // centi-degrees C
            if SensorCatalog.validTemp(c) { b.temperatureC = c; r.hasTemperature = true }
        }
        b.voltageV = Double(Self.int(props, "Voltage") ?? 0) / 1000.0
        let mA = Self.signed64(props, "Amperage") ?? Self.signed64(props, "InstantAmperage") ?? 0
        b.amperageA = Double(mA) / 1000.0
        b.powerW = b.voltageV * b.amperageA

        let toEmpty = Self.int(props, "AvgTimeToEmpty") ?? 65535
        let toFull = Self.int(props, "AvgTimeToFull") ?? 65535
        if b.isCharging, toFull != 65535, toFull >= 0 { b.minutesRemaining = toFull }
        else if !b.isPluggedIn, toEmpty != 65535, toEmpty >= 0 { b.minutesRemaining = toEmpty }

        if b.isPluggedIn, let ad = props["AdapterDetails"] as? [String: Any] {
            if let w = Self.int(ad, "Watts"), w > 0 { b.adapterWatts = w }
            if let n = (ad["Name"] as? String) ?? (ad["Description"] as? String), !n.isEmpty { b.adapterName = n }
        }
        if let pt = props["PowerTelemetryData"] as? [String: Any],
           let mw = (pt["SystemPowerIn"] as? NSNumber)?.int64Value, mw > 0 {
            r.adapterInputW = Double(mw) / 1000.0
        }
        r.battery = b
        return r
    }
}
