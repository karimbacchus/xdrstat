// Central store. OWNER: lead.
// Samplers run on a private serial queue; results are published on the main actor.

import Foundation
import SwiftUI

/// Fixed-size ring buffer of Doubles for graphs. Oldest first when read via `values`.
struct History: Sendable, Equatable {
    private(set) var values: [Double] = []
    let capacity: Int
    init(capacity: Int = 120) { self.capacity = capacity }
    mutating func append(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    var last: Double? { values.last }
    var max: Double { values.max() ?? 0 }
}

/// Which panels are currently open, so samplers can skip expensive work.
struct DetailFlags: Sendable {
    var cpu = false, memory = false, network = false, sensors = false
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var chip = ChipSnapshot()
    @Published private(set) var memory = MemorySnapshot()
    @Published private(set) var network = NetworkSnapshot()
    @Published private(set) var sensors = SensorsSnapshot()

    // Graph histories (one sample per tick)
    @Published private(set) var cpuHistory = History()          // 0...1
    @Published private(set) var cpuUserHistory = History()      // 0...1
    @Published private(set) var cpuSystemHistory = History()    // 0...1
    @Published private(set) var gpuHistory = History()          // 0...1
    @Published private(set) var memoryPressureHistory = History() // 0...1
    @Published private(set) var memoryUsedHistory = History()   // 0...1
    @Published private(set) var netDownHistory = History()      // bytes/s
    @Published private(set) var netUpHistory = History()        // bytes/s
    @Published private(set) var cpuTempHistory = History()      // °C
    @Published private(set) var gpuTempHistory = History()      // °C
    @Published private(set) var systemPowerHistory = History()  // W
    /// Increments once per published sample; graph-style menu bar labels key on it so they keep
    /// scrolling after the histories reach capacity.
    @Published private(set) var sampleCount = 0

    /// Set by panels on appear/disappear.
    var detail = DetailFlags() { didSet { queue.async { [d = detail] in self.detailBox = d } } }

    private let queue = DispatchQueue(label: "xdrstat.sampler", qos: .utility)
    private nonisolated(unsafe) var detailBox = DetailFlags()
    private nonisolated(unsafe) var timer: DispatchSourceTimer?
    private nonisolated(unsafe) var tick = 0

    // Samplers are only touched on `queue`.
    private nonisolated(unsafe) let chipSampler = ChipSampler()
    private nonisolated(unsafe) let memorySampler = MemorySampler()
    private nonisolated(unsafe) let networkSampler = NetworkSampler()
    private nonisolated(unsafe) let sensorsSampler = SensorsSampler()

    private init() {
        start(interval: AppSettings.shared.updateInterval)
    }

    private var currentInterval: TimeInterval?

    func start(interval: TimeInterval) {
        let iv = interval.isFinite ? max(0.25, interval) : 1
        // The Settings slider calls this on every step; only rebuild the timer when the value changes,
        // and don't fire an extra immediate sample on a restart.
        if iv == currentInterval, timer != nil { return }
        let first = currentInterval == nil
        currentInterval = iv
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: first ? .now() : .now() + iv, repeating: iv, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.sampleOnQueue() }
        timer = t
        t.resume()
    }

    private nonisolated func sampleOnQueue() {
        let d = detailBox
        tick += 1
        let chip = chipSampler.sample(detailed: d.cpu)
        let mem = memorySampler.sample(detailed: d.memory)
        let net = networkSampler.sample(detailed: d.network)
        // Sensors are comparatively expensive (hundreds of SMC keys): every tick only
        // when the panel is open, otherwise every other tick for menu bar headline temps.
        let sens: SensorsSnapshot? = (d.sensors || tick % 2 == 1) ? sensorsSampler.sample(detailed: d.sensors) : nil
        Task { @MainActor in self.publish(chip: chip, memory: mem, network: net, sensors: sens) }
    }

    private func publish(chip: ChipSnapshot, memory: MemorySnapshot, network: NetworkSnapshot, sensors: SensorsSnapshot?) {
        self.chip = chip
        self.memory = memory
        self.network = network
        sampleCount &+= 1
        cpuHistory.append(chip.cpu.usage)
        cpuUserHistory.append(chip.cpu.user)
        cpuSystemHistory.append(chip.cpu.system)
        gpuHistory.append(chip.gpu.utilization)
        memoryPressureHistory.append(memory.pressure)
        memoryUsedHistory.append(memory.usedFraction)
        netDownHistory.append(network.downBytesPerSec)
        netUpHistory.append(network.upBytesPerSec)
        if let s = sensors {
            self.sensors = s
            if let t = s.cpuTemperature { cpuTempHistory.append(t) }
            if let t = s.gpuTemperature { gpuTempHistory.append(t) }
            if let p = s.systemPowerW { systemPowerHistory.append(p) }
        }
    }
}
