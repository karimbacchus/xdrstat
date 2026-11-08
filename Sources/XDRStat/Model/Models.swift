// Shared data contract between samplers (producers) and UI (consumer).
// OWNER: lead. Do not change existing fields without coordinating; adding
// optional fields with defaults is fine.

import Foundation

// MARK: - CPU / GPU

enum CoreKind: String, Codable, Sendable {
    case superCore      // M5 "Super" cores (IOReport: PCPU0-5 / PACC_n)
    case performance    // M5 "Performance" cores (IOReport: MCPU0x, MCPU1x)

    var displayName: String { self == .superCore ? "Super" : "Performance" }
}

struct CoreSample: Identifiable, Sendable, Equatable {
    var id: Int                 // logical CPU index from host_processor_info
    var kind: CoreKind
    var cluster: Int            // 0 = super cluster, 1/2 = performance clusters
    var user: Double            // 0...1
    var system: Double          // 0...1
    var usage: Double { min(1, user + system) }
    var frequencyMHz: Double?   // estimated effective freq (nil if unknown)
    var powerW: Double?
}

struct ClusterSample: Identifiable, Sendable, Equatable {
    var id: Int                 // cluster index
    var name: String            // "Super", "Performance 1", "Performance 2"
    var kind: CoreKind
    var usage: Double           // 0...1 averaged across its cores
    var frequencyMHz: Double?   // active-residency weighted
    var maxFrequencyMHz: Double?
    var powerW: Double?
}

struct ProcessUsage: Identifiable, Sendable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var cpuPercent: Double      // percent of ONE core (can exceed 100)
    var memoryBytes: UInt64     // physical footprint
    var appPath: String? = nil  // owning .app bundle when grouped (for the icon)
}

struct CPUSnapshot: Sendable, Equatable {
    var cores: [CoreSample] = []
    var clusters: [ClusterSample] = []
    var user: Double = 0        // 0...1 across all cores
    var system: Double = 0
    var idle: Double = 1
    var usage: Double { min(1, user + system) }
    var powerW: Double?         // whole CPU complex
    var loadAverage: [Double] = [0, 0, 0]
    var uptime: TimeInterval = 0
    var processCount: Int = 0
    var threadCount: Int = 0
    var topProcesses: [ProcessUsage] = []   // only filled when detailed == true
}

struct GPUSnapshot: Sendable, Equatable {
    var name: String = "GPU"
    var coreCount: Int = 0
    var utilization: Double = 0         // 0...1 ("Device Utilization %")
    var rendererUtilization: Double = 0 // 0...1
    var tilerUtilization: Double = 0    // 0...1
    var frequencyMHz: Double?
    var maxFrequencyMHz: Double?
    var powerW: Double?
    var memoryInUseBytes: UInt64 = 0
    var memoryAllocatedBytes: UInt64 = 0
}

/// Other SoC power consumers from IOReport "Energy Model" (ANE, DRAM, display...).
struct PowerComponent: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var watts: Double
}

struct ChipSnapshot: Sendable, Equatable {
    var cpu = CPUSnapshot()
    var gpu = GPUSnapshot()
    var components: [PowerComponent] = []   // e.g. "ANE", "DRAM", "Display", "Fabric"
    var chipName: String = "Apple M5"
}

// MARK: - Memory

enum MemoryPressureLevel: String, Sendable { case normal, warning, critical }

struct MemorySnapshot: Sendable, Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0          // app + wired + compressed
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0        // file-backed / purgeable
    var free: UInt64 = 0
    var pressure: Double = 0      // 0...1 (like Activity Monitor's graph)
    var pressureLevel: MemoryPressureLevel = .normal
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pageInsPerSec: Double = 0
    var pageOutsPerSec: Double = 0
    var compressionRatio: Double?
    var topProcesses: [ProcessUsage] = []   // only filled when detailed == true
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

// MARK: - Network

enum InterfaceKind: String, Sendable { case wifi, ethernet, thunderbolt, vpn, other }

struct NetworkInterfaceInfo: Identifiable, Sendable, Equatable {
    var id: String { bsdName }
    var bsdName: String           // en0
    var displayName: String       // "Wi‑Fi"
    var kind: InterfaceKind
    var isPrimary: Bool
    var isUp: Bool
    var ipv4: [String] = []
    var ipv6: [String] = []
    var macAddress: String?
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
}

struct WiFiInfo: Sendable, Equatable {
    var ssid: String?             // nil when location permission is missing
    var rssi: Int?                // dBm
    var noise: Int?
    var txRateMbps: Double?
    var channel: String?          // "149 (5 GHz, 80 MHz)"
    var phyMode: String?          // "802.11be"
    var security: String?
}

struct NetworkSnapshot: Sendable, Equatable {
    var downBytesPerSec: Double = 0   // primary/all physical interfaces
    var upBytesPerSec: Double = 0
    var totalDown: UInt64 = 0         // since boot
    var totalUp: UInt64 = 0
    var interfaces: [NetworkInterfaceInfo] = []
    var wifi: WiFiInfo?
    var publicIPv4: String?
    var gateway: String?
    var dnsServers: [String] = []
}

// MARK: - Sensors

enum SensorGroup: String, CaseIterable, Sendable, Identifiable {
    case cpu = "CPU", gpu = "GPU", memory = "Memory", soc = "SoC", storage = "Storage",
         battery = "Battery", display = "Display", power = "Power Delivery",
         wireless = "Wireless", enclosure = "Enclosure", other = "Other"
    var id: String { rawValue }
}

enum SensorUnit: String, Sendable { case celsius, rpm, watts, volts, amps, percent }

struct Sensor: Identifiable, Sendable, Equatable {
    var id: String                // SMC key or HID product name, stable
    var name: String              // friendly: "CPU Super Core 3"
    var group: SensorGroup
    var value: Double
    var unit: SensorUnit
}

struct FanSample: Identifiable, Sendable, Equatable {
    var id: Int
    var name: String              // "Left Fan"
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double?
    var fraction: Double { maxRPM <= minRPM ? 0 : max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) }
}

struct BatterySnapshot: Sendable, Equatable {
    var present: Bool = false
    var percent: Double = 0              // 0...1
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var isFullyCharged: Bool = false
    var minutesRemaining: Int?           // to empty or to full
    var cycleCount: Int = 0
    var healthFraction: Double?          // FullChargeCapacity / DesignCapacity
    var designCapacitymAh: Int = 0
    var fullChargeCapacitymAh: Int = 0
    var temperatureC: Double?
    var voltageV: Double = 0
    var amperageA: Double = 0            // negative = discharging
    var powerW: Double = 0               // signed: negative = discharging
    var adapterWatts: Int?
    var adapterName: String?
}

struct SensorsSnapshot: Sendable, Equatable {
    var temperatures: [Sensor] = []      // all valid, friendly-named temps
    var fans: [FanSample] = []
    var power: [Sensor] = []             // watts: "System Total", "Battery", "Adapter In"...
    var voltages: [Sensor] = []
    var currents: [Sensor] = []
    var battery = BatterySnapshot()

    // Headline values for menu bar & summaries (nil if unavailable)
    var cpuTemperature: Double?          // hottest-average of CPU dies
    var gpuTemperature: Double?
    var systemPowerW: Double?            // SMC PSTR
}
