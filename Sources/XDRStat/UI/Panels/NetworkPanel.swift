import SwiftUI

struct NetworkPanel: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        NetworkPanelContent(state: MonitorState(monitor, settings))
            .onAppear { monitor.detail.network = true }
            .onDisappear { monitor.detail.network = false }
    }
}

struct NetworkPanelContent: View {
    var state: MonitorState
    private var n: NetworkSnapshot { state.network }

    var body: some View {
        PanelFrame {
            traffic
            if let w = n.wifi { wifi(w) }
            publicIP
            ipAddresses
            if n.gateway != nil || !n.dnsServers.isEmpty { router }
            interfaces
            totals
            PanelFooter()
        }
    }

    // MARK: traffic

    private func rateBlock(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 2) {
            ValueLabel(Fmt.rateParts(value), size: 20, weight: .medium)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var traffic: some View {
        let peakUp = state.netUpHistory.max, peakDown = state.netDownHistory.max
        let scale = max(max(peakUp, peakDown), 20_000)
        return Card(spacing: 6) {
            HStack(alignment: .top) {
                rateBlock("Upload", n.upBytesPerSec, Theme.pink)
                rateBlock("Download", n.downBytesPerSec, Theme.accent)
            }
            MirroredBars(up: state.netUpHistory.values, down: state.netDownHistory.values, scale: scale,
                         upColor: Theme.pink, downColor: Theme.accent)
                .frame(height: 84)
            HStack(alignment: .firstTextBaseline) {
                peak("Upload", peakUp)
                Spacer()
                peak("Download", peakDown)
            }
        }
    }

    private func peak(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
            ValueLabel(Fmt.rateParts(v), size: 13, weight: .medium)
        }
    }

    // MARK: Wi-Fi

    private func wifi(_ w: WiFiInfo) -> some View {
        Card(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "wifi").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                if let s = w.ssid { Text(s).font(.system(size: 13)).lineLimit(1) }
                else {
                    Text("Wi‑Fi").font(.system(size: 13))
                    Button { PanelActions.requestLocation() } label: {
                        Label("Show name", systemImage: "location").font(.system(size: 11)).foregroundStyle(.orange)
                            .lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("macOS only reveals the Wi‑Fi name to apps with Location access. Click to grant it.")
                }
                Spacer()
                if let r = w.rssi { SignalBars(rssi: r); ValueLabel(value: "\(r)", unit: "dBm") }
            }
            if let v = w.txRateMbps { InfoRow(label: "Tx rate", value: String(format: "%.0f", v), unit: "Mbps") }
            if let v = w.noise { InfoRow(label: "Noise", value: "\(v)", unit: "dBm") }
            if let v = w.channel { InfoRow(label: "Channel", value: v) }
            if let v = w.phyMode { InfoRow(label: "PHY mode", value: v) }
            if let v = w.security { InfoRow(label: "Security", value: v) }
        }
    }

    // MARK: addresses

    @ViewBuilder private var publicIP: some View {
        Card(spacing: 3) {
            CardTitle("Public IP Addresses")
            if state.fetchPublicIP {
                if let ip = n.publicIPv4 { CopyValue(text: ip) } else { Text("Looking up…").font(.system(size: 12.5)).foregroundStyle(.secondary) }
            } else {
                Button { PanelActions.openSettings() } label: {
                    Text("Off — enable in Settings").font(.system(size: 12.5)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
            }
        }
    }

    private var activeInterfaces: [NetworkInterfaceInfo] {
        n.interfaces.filter { $0.isUp && ($0.isPrimary || !$0.ipv4.isEmpty) }
    }

    private func sortedV6(_ l: [String]) -> [String] {
        l.filter { !$0.lowercased().hasPrefix("fe80") } + l.filter { $0.lowercased().hasPrefix("fe80") }
    }

    @ViewBuilder private var ipAddresses: some View {
        let list = activeInterfaces
        if !list.isEmpty {
            Card(spacing: 3) {
                CardTitle("IP Addresses")
                ForEach(list) { i in
                    if list.count > 1 {
                        Text("\(i.displayName) · \(i.bsdName)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    ForEach(i.ipv4, id: \.self) { CopyValue(text: $0) }
                    ForEach(Array(sortedV6(i.ipv6).prefix(3)), id: \.self) { CopyValue(text: $0) }
                }
            }
        }
    }

    private var router: some View {
        Card(spacing: 3) {
            CardTitle("Router & DNS")
            if let g = n.gateway { CopyRow(label: "Gateway", value: g) }
            ForEach(Array(n.dnsServers.prefix(3).enumerated()), id: \.offset) { i, d in
                CopyRow(label: i == 0 ? "DNS" : "", value: d)
            }
        }
    }

    // MARK: interfaces

    private func icon(_ k: InterfaceKind) -> String {
        switch k {
        case .wifi: "wifi"; case .ethernet: "cable.connector.horizontal"; case .thunderbolt: "bolt.horizontal"
        case .vpn: "lock.shield"; case .other: "network"
        }
    }

    @ViewBuilder private var interfaces: some View {
        let list = activeInterfaces
        if !list.isEmpty {
            Card(spacing: 7) {
                CardTitle("Interfaces")
                ForEach(list) { InterfaceRow(info: $0, icon: icon($0.kind)) }
            }
        }
    }

    private var totals: some View {
        Card(spacing: 3) {
            CardTitle("Since Boot")
            LegendRow(color: Theme.pink, name: "Uploaded", value: ValueLabel(Fmt.bytesParts(n.totalUp), size: 13, weight: .medium), nameColor: .primary)
            LegendRow(color: Theme.accent, name: "Downloaded", value: ValueLabel(Fmt.bytesParts(n.totalDown), size: 13, weight: .medium), nameColor: .primary)
        }
    }
}

struct SignalBars: View {
    var rssi: Int
    var body: some View {
        let level = rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : rssi >= -85 ? 1 : 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i < level ? Color.primary.opacity(0.85) : Color.primary.opacity(0.18))
                    .frame(width: 3.5, height: 4 + CGFloat(i) * 3)
            }
        }
        .frame(height: 13)
    }
}

struct InterfaceRow: View {
    var info: NetworkInterfaceInfo
    var icon: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(info.displayName).font(.system(size: 12.5)).lineLimit(1)
                    if info.isPrimary {
                        Text("PRIMARY").font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.good.opacity(0.2))).foregroundStyle(Theme.good)
                    }
                }
                Text(info.bsdName + (info.macAddress.flatMap { $0 == "02:00:00:00:00:00" ? nil : " · \($0)" } ?? "")).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) { Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.pink)
                    ValueLabel(Fmt.rateParts(info.upBytesPerSec), size: 11.5) }
                HStack(spacing: 4) { Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.accent)
                    ValueLabel(Fmt.rateParts(info.downBytesPerSec), size: 11.5) }
            }
        }
        .hoverHighlight()
    }
}
