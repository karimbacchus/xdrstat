// Central store. OWNER: lead.
// Samplers run on a private serial queue; results are published on the main actor.

import Combine
import Foundation
import SwiftUI

/// Fixed-size ring buffer of Doubles for graphs. Oldest first when read via `values`.
struct History: Sendable, Equatable {
    private(set) var values: [Double] = []
    let capacity: Int
    init(capacity: Int = 120) { self.capacity = capacity }
    mutating func append(_ v: Double) {
        values.append(v.isFinite ? v : 0)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    var last: Double? { values.last }
    var max: Double { values.max() ?? 0 }
}

/// Which panels are currently open, so samplers can skip expensive work.
struct DetailFlags: Sendable, Equatable {
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
    @Published private(set) var cpuUserHistory = History()      // 0...1
    @Published private(set) var cpuSystemHistory = History()    // 0...1
    @Published private(set) var gpuHistory = History()          // 0...1
    @Published private(set) var memoryPressureHistory = History() // 0...1
    @Published private(set) var netDownHistory = History()      // bytes/s
    @Published private(set) var netUpHistory = History()        // bytes/s
    @Published private(set) var cpuTempHistory = History()      // °C
    @Published private(set) var gpuTempHistory = History()      // °C
    @Published private(set) var systemPowerHistory = History()  // W
    /// The first pinned sensor that exists, for the menu bar sparkline when sensors are pinned.
    @Published private(set) var pinnedHistory = History()
    private var pinnedHistoryID: String?

    /// Set by panels on appear/disappear.
    var detail = DetailFlags() {
        didSet {
            guard detail != oldValue else { return }
            let new = detail, old = oldValue
            queue.async { self.detailChanged(from: old, to: new) }
        }
    }

    private let queue = DispatchQueue(label: "xdrstat.sampler", qos: .utility)
    private nonisolated(unsafe) var detailBox = DetailFlags()
    /// Sensor IDs pinned to the menu bar: read even while the Sensors panel is closed.
    private nonisolated(unsafe) var pinnedBox: Set<String> = []
    private nonisolated(unsafe) var timer: DispatchSourceTimer?
    private nonisolated(unsafe) var tick = 0
    private var bag = Set<AnyCancellable>()

    /// Samplers are created lazily and only touched on `queue`: building them walks ~4,000 SMC keys
    /// and the IOReport channel list, which shouldn't hold up launch on the main thread.
    private final class Samplers {
        let chip = ChipSampler()
        let memory = MemorySampler()
        let network = NetworkSampler()
        let sensors = SensorsSampler()
    }
    private nonisolated(unsafe) var samplerStore: Samplers?
    private nonisolated var samplers: Samplers {
        if let s = samplerStore { return s }
        let s = Samplers()
        samplerStore = s
        return s
    }

    private init() {
        start(interval: AppSettings.shared.updateInterval)
        AppSettings.shared.$menuBarSensorIDs
            .sink { [weak self] ids in
                let set = Set(ids)
                self?.queue.async { self?.pinnedBox = set }
            }
            .store(in: &bag)
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
        // Generous leeway lets macOS coalesce our wakeups with others; rates use real elapsed time anyway.
        t.schedule(deadline: first ? .now() : .now() + iv, repeating: iv, leeway: .milliseconds(max(50, Int(iv * 100))))
        t.setEventHandler { [weak self] in self?.sampleOnQueue() }
        timer = t
        t.resume()
    }

    private nonisolated func sampleOnQueue() {
        let d = detailBox
        let s = samplers
        tick += 1
        let chip = s.chip.sample(detailed: d.cpu)
        let mem = s.memory.sample(detailed: d.memory)
        let net = s.network.sample(detailed: d.network)
        // Sensors are comparatively expensive (dozens of SMC calls): every tick only when the
        // panel is open, otherwise every other tick for the menu bar temperature.
        let sens: SensorsSnapshot? = (d.sensors || tick % 2 == 1) ? s.sensors.sample(detailed: d.sensors, pinned: pinnedBox) : nil
        Task { @MainActor in self.publish(chip: chip, memory: mem, network: net, sensors: sens) }
    }

    /// A panel just opened: fetch its full data now rather than on the next tick, so it doesn't open
    /// half-filled (only the headline temperatures, no process list, no Wi‑Fi) and then jump in size.
    private nonisolated func detailChanged(from old: DetailFlags, to new: DetailFlags) {
        detailBox = new
        let s = samplers
        if new.cpu && !old.cpu {
            // Per-process CPU needs two scans; take the first now and the second shortly after.
            s.chip.beginProcessSampling()
            queue.asyncAfter(deadline: .now() + 0.35) {
                guard self.detailBox.cpu, let p = self.samplers.chip.processesIfStillPending() else { return }
                Task { @MainActor in
                    self.chip.cpu.topProcesses = p.top
                    self.chip.cpu.processCount = p.processes
                    self.chip.cpu.threadCount = p.threads
                }
            }
        }
        let mem = new.memory && !old.memory ? s.memory.sample(detailed: true) : nil
        let net = new.network && !old.network ? s.network.sample(detailed: true) : nil
        let sens = new.sensors && !old.sensors ? s.sensors.sample(detailed: true, pinned: pinnedBox) : nil
        guard mem != nil || net != nil || sens != nil else { return }
        Task { @MainActor in
            if let mem { self.memory = mem }
            if let net { self.network = net }
            if let sens { self.sensors = sens }
        }
    }

    private func publish(chip: ChipSnapshot, memory: MemorySnapshot, network: NetworkSnapshot, sensors: SensorsSnapshot?) {
        self.chip = chip
        self.memory = memory
        self.network = network
        cpuUserHistory.append(chip.cpu.user)
        cpuSystemHistory.append(chip.cpu.system)
        gpuHistory.append(chip.gpu.utilization)
        memoryPressureHistory.append(memory.pressure)
        netDownHistory.append(network.downBytesPerSec)
        netUpHistory.append(network.upBytesPerSec)
        if let s = sensors {
            self.sensors = s
            if let t = s.cpuTemperature { cpuTempHistory.append(t) }
            if let t = s.gpuTemperature { gpuTempHistory.append(t) }
            if let p = s.systemPowerW { systemPowerHistory.append(p) }
            recordPinned(s)
        }
    }

    private func recordPinned(_ s: SensorsSnapshot) {
        let ids = AppSettings.shared.menuBarSensorIDs
        guard !ids.isEmpty else {
            if pinnedHistoryID != nil { pinnedHistoryID = nil; pinnedHistory = History() }
            return
        }
        var byID: [String: Double] = [:]
        for x in s.temperatures + s.power + s.voltages + s.currents { byID[x.id] = x.value }
        guard let id = ids.first(where: { byID[$0] != nil }), let v = byID[id] else { return }
        if id != pinnedHistoryID { pinnedHistoryID = id; pinnedHistory = History() }
        pinnedHistory.append(v)
    }
}
