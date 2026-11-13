import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 400)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings
    @LocalState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @LocalState private var loginError: String?

    /// Prevents the last visible menu item from being turned off.
    private func guarded(_ kp: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: kp] }, set: { new in
            let count = [settings.showCPU, settings.showMemory, settings.showNetwork, settings.showSensors].filter { $0 }.count
            if !new && count <= 1 { NSSound.beep(); return }
            settings[keyPath: kp] = new
        })
    }

    private var onlyOne: Bool {
        [settings.showCPU, settings.showMemory, settings.showNetwork, settings.showSensors].filter { $0 }.count <= 1
    }

    var body: some View {
        Form {
            Section {
                Toggle("CPU & GPU", isOn: guarded(\.showCPU))
                Toggle("Memory", isOn: guarded(\.showMemory))
                Toggle("Network", isOn: guarded(\.showNetwork))
                Toggle("Sensors", isOn: guarded(\.showSensors))
            } header: { Text("Menu Bar Items") } footer: {
                Text(onlyOne ? "At least one item must stay visible." : "Choose which items appear in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Menu bar style", selection: $settings.menuBarStyle) {
                    Text("Graph + value").tag(MenuBarStyle.graph)
                    Text("Value only").tag(MenuBarStyle.text)
                    Text("Icon + value").tag(MenuBarStyle.compact)
                }
                Picker("Temperature", selection: $settings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
            }

            Section {
                HStack {
                    Text("Update interval")
                    Slider(value: $settings.updateInterval, in: 0.5...5, step: 0.5)
                    Text(String(format: "%.1f s", settings.updateInterval)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            } footer: {
                Text("Shorter intervals feel more responsive but use slightly more energy.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve XDRStat in System Settings → General → Login Items." : nil
        } catch {
            loginError = "Couldn’t change login item (\(error.localizedDescription)). This usually needs a signed app in /Applications."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct NetworkSettings: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Look up public IP address", isOn: $settings.fetchPublicIP)
            } footer: {
                Text("When enabled, XDRStat asks an external web service for your public IPv4 address. It is off by default so the app makes no network requests of its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    @LocalState private var update: UpdateCheck.State = .idle

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
            Text("XDRStat").font(.system(size: 22, weight: .semibold))
            Text("Version \(UpdateCheck.currentVersion)")
                .font(.callout).foregroundStyle(.secondary)
            Text("A lightweight system monitor for the menu bar — CPU, GPU, memory, network and sensors for Apple silicon.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 320).padding(.top, 4)
            updateRow.frame(height: 28).padding(.top, 6)
            HStack(spacing: 18) {
                Link("xdrstat.com", destination: UpdateCheck.website)
                Link("Source on GitHub", destination: UpdateCheck.repository)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder private var updateRow: some View {
        switch update {
        case .idle:
            Button("Check for Updates") { runCheck() }
                .help("Asks GitHub for the latest release. XDRStat never checks on its own.")
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        case .upToDate:
            Label("XDRStat is up to date.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
        case .available(let version, let page):
            HStack(spacing: 10) {
                Text("Version \(version) is available.")
                Button("Download…") { NSWorkspace.shared.open(page) }.keyboardShortcut(.defaultAction)
            }
        case .failed:
            HStack(spacing: 10) {
                Text("Couldn’t reach GitHub.").foregroundStyle(.secondary)
                Button("Try Again") { runCheck() }
            }
        }
    }

    private func runCheck() {
        update = .checking
        Task { @MainActor in update = await UpdateCheck.check() }
    }
}
