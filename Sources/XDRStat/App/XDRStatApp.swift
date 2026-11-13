// App entry. OWNER: lead.
// Menu bar items and dropdown panels are AppKit (UI/StatusBar/StatusBarController.swift); the SwiftUI
// App only hosts the Settings scene, and its body never observes per-second state.

import SwiftUI
import ServiceManagement

@main
struct XDRStatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `XDRStat --register-login-item` / `--unregister-login-item`: same API as the Settings toggle.
        let args = CommandLine.arguments
        if args.contains("--register-login-item") || args.contains("--unregister-login-item") {
            do {
                if args.contains("--register-login-item") { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                print("login item status: \(SMAppService.mainApp.status.rawValue) (1 = enabled, 2 = requires approval)")
                exit(0)
            } catch {
                print("login item error: \(error)")
                exit(1)
            }
        }
    }

    var body: some Scene {
        Settings {
            SettingsView().environmentObject(SystemMonitor.shared).environmentObject(AppSettings.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["XDRSTAT_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { SnapshotRunner.run(into: dir) }
            return
        }
        // One copy only: a second one (say, a build next to the installed app) would double every menu bar item.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        // QA: XDRSTAT_APPEARANCE=light|dark overrides the system appearance for this run.
        switch ProcessInfo.processInfo.environment["XDRSTAT_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        statusBar = StatusBarController()
        // QA: XDRSTAT_OPEN="cpu,close,sensors" runs those steps 4 s apart.
        if let steps = ProcessInfo.processInfo.environment["XDRSTAT_OPEN"]?.split(separator: ",") {
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4 * Double(i + 1)) { [weak self] in self?.statusBar?.debugOpen(String(step)) }
            }
        }
    }
}
