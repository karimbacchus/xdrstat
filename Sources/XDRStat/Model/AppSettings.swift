// User preferences. OWNER: lead (UI agent may ADD settings).

import Foundation
import SwiftUI

enum TemperatureUnit: String, CaseIterable, Identifiable { case celsius, fahrenheit; var id: String { rawValue } }

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case graph      // sparkline/bars + value
    case text       // value only
    case compact    // icon + value
    var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var showCPU: Bool { didSet { d.set(showCPU, forKey: "showCPU") } }
    @Published var showMemory: Bool { didSet { d.set(showMemory, forKey: "showMemory") } }
    @Published var showNetwork: Bool { didSet { d.set(showNetwork, forKey: "showNetwork") } }
    @Published var showSensors: Bool { didSet { d.set(showSensors, forKey: "showSensors") } }
    @Published var updateInterval: Double {
        didSet { d.set(updateInterval, forKey: "updateInterval"); SystemMonitor.shared.start(interval: updateInterval) }
    }
    @Published var temperatureUnit: TemperatureUnit { didSet { d.set(temperatureUnit.rawValue, forKey: "tempUnit") } }
    @Published var menuBarStyle: MenuBarStyle { didSet { d.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    @Published var fetchPublicIP: Bool { didSet { d.set(fetchPublicIP, forKey: "fetchPublicIP") } }
    /// Sensor IDs shown in the menu bar sensors item (empty → CPU temp).
    @Published var menuBarSensorIDs: [String] { didSet { d.set(menuBarSensorIDs, forKey: "menuBarSensorIDs") } }

    private init() {
        d.register(defaults: ["showCPU": true, "showMemory": true, "showNetwork": true, "showSensors": true,
                              "updateInterval": 1.0, "tempUnit": "celsius", "menuBarStyle": "graph",
                              "fetchPublicIP": false])
        showCPU = d.bool(forKey: "showCPU")
        showMemory = d.bool(forKey: "showMemory")
        showNetwork = d.bool(forKey: "showNetwork")
        showSensors = d.bool(forKey: "showSensors")
        updateInterval = d.double(forKey: "updateInterval")
        temperatureUnit = TemperatureUnit(rawValue: d.string(forKey: "tempUnit") ?? "") ?? .celsius
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .graph
        fetchPublicIP = d.bool(forKey: "fetchPublicIP")
        menuBarSensorIDs = d.stringArray(forKey: "menuBarSensorIDs") ?? []
    }
}
