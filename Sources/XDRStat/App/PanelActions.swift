// Actions panels can trigger. OWNER: lead. Implemented by StatusBarController.
import AppKit
import CoreLocation

@MainActor enum PanelActions {
    /// Closes whichever dropdown panel is open.
    static var close: () -> Void = {}
    /// Closes the panel and shows the Settings window.
    static var openSettings: () -> Void = {}
    /// Asks for Location access (macOS gates the Wi‑Fi SSID behind it). If it was already
    /// denied, macOS won't ask again, so open the Location Services pane instead.
    static func requestLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            NSApp.activate()
            locationManager.requestWhenInUseAuthorization()
        default:
            close()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    private static let locationManager = CLLocationManager()

    /// Opens an app by bundle identifier (e.g. "com.apple.ActivityMonitor") and closes the panel.
    static func open(bundleID: String) {
        close()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
