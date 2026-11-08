import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

final class NetworkSampler {
    private struct Counters { var rx: UInt64; var tx: UInt64; var time: UInt64 }
    private var last: [String: Counters] = [:]
    private var tick = 0
    private var cachedWiFi: WiFiInfo?
    private var wifiClient: CWWiFiClient?
    private var store: SCDynamicStore?
    private var ifaceMeta: [String: (name: String, kind: InterfaceKind)] = [:]
    private var metaTick = -1000
    private let ip = PublicIPFetcher()

    private func dynStore() -> SCDynamicStore? {
        if store == nil { store = SCDynamicStoreCreate(nil, "XDRStat" as CFString, nil, nil) }
        return store
    }

    func sample(detailed: Bool) -> NetworkSnapshot {
        tick += 1
        var snap = NetworkSnapshot()
        let now = DispatchTime.now().uptimeNanoseconds

        if tick - metaTick >= 30 { refreshMeta(); metaTick = tick }

        // Primary / gateway / DNS
        var primary: String?
        if let s = dynStore() {
            if let d = SCDynamicStoreCopyValue(s, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
                primary = d["PrimaryInterface"] as? String
                snap.gateway = d["Router"] as? String
            }
            if let d = SCDynamicStoreCopyValue(s, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
                snap.dnsServers = d["ServerAddresses"] as? [String] ?? []
            }
        }

        let counters = readCounters()
        let addrs = readAddresses()

        var infos: [NetworkInterfaceInfo] = []
        for c in counters {
            let name = c.name
            let isUp = (c.flags & UInt32(IFF_UP)) != 0 && (c.flags & UInt32(IFF_RUNNING)) != 0
            let a = addrs[name]
            let meta = ifaceMeta[name]
            let ipv4 = a?.v4 ?? []
            var ipv6 = a?.v6 ?? []
            let nonLL = ipv6.filter { !$0.lowercased().hasPrefix("fe80") }
            if !nonLL.isEmpty { ipv6 = nonLL }

            // rates
            var down = 0.0, up = 0.0
            if let p = last[name], c.rx >= p.rx, c.tx >= p.tx {
                let dt = Double(now &- p.time) / 1e9
                if dt > 0.05 { down = Double(c.rx - p.rx) / dt; up = Double(c.tx - p.tx) / dt }
            }
            last[name] = Counters(rx: c.rx, tx: c.tx, time: now)

            var kind: InterfaceKind = meta?.kind ?? .other
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { kind = .vpn }
            else if name.hasPrefix("bridge") && kind == .other { kind = .thunderbolt }
            else if name.hasPrefix("en") && kind == .other { kind = .ethernet }

            // Filter
            let hasAddr = !ipv4.isEmpty || !ipv6.isEmpty
            let hasTraffic = c.rx > 0 || c.tx > 0
            if name.hasPrefix("en") {
                // keep (Wi-Fi, ethernet, thunderbolt); drop dead ones with no traffic ever and no address
                if !hasAddr && !hasTraffic { continue }
            } else if kind == .vpn {
                if !(hasAddr && hasTraffic && isUp) { continue }
                if ipv4.isEmpty && ipv6.allSatisfy({ $0.lowercased().hasPrefix("fe80") }) { continue }
            } else if name.hasPrefix("bridge") {
                if !(isUp && (!ipv4.isEmpty || hasTraffic)) { continue }
            } else {
                continue // lo0, awdl, llw, anpi, ap, gif, stf, ...
            }

            infos.append(NetworkInterfaceInfo(
                bsdName: name, displayName: meta?.name ?? name, kind: kind,
                isPrimary: name == primary, isUp: isUp, ipv4: ipv4, ipv6: ipv6,
                macAddress: a?.mac, downBytesPerSec: down, upBytesPerSec: up,
                totalDown: c.rx, totalUp: c.tx))
        }
        last = last.filter { k, _ in counters.contains { $0.name == k } }
        infos.sort { ($0.isPrimary ? 0 : 1, $0.bsdName) < ($1.isPrimary ? 0 : 1, $1.bsdName) }
        snap.interfaces = infos

        for i in infos where i.bsdName.hasPrefix("en") && i.isUp {
            snap.downBytesPerSec += i.downBytesPerSec
            snap.upBytesPerSec += i.upBytesPerSec
        }
        for i in infos where i.bsdName.hasPrefix("en") {
            snap.totalDown &+= i.totalDown
            snap.totalUp &+= i.totalUp
        }

        // Wi-Fi
        // CoreWLAN is the costliest call here and only the Network panel shows it.
        if detailed && (tick % 2 == 1 || cachedWiFi == nil) { cachedWiFi = readWiFi() }
        snap.wifi = cachedWiFi

        snap.publicIPv4 = ip.current(primary: primary)
        return snap
    }

    // MARK: counters (64-bit via NET_RT_IFLIST2)

    private struct RawCounters { var name: String; var flags: UInt32; var rx: UInt64; var tx: UInt64 }

    private func readCounters() -> [RawCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // The table can grow between the size query and the read (VPN up, USB Ethernet plugged in),
        // which fails with ENOMEM; allocate headroom and retry a couple of times.
        var len = 0
        var buf: [UInt8] = []
        var ok = false
        for _ in 0..<3 {
            guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [] }
            len += len / 8 + 512
            buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 { ok = true; break }
            if errno != ENOMEM { return [] }
        }
        guard ok else { return [] }
        var out: [RawCounters] = []
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: if_msghdr.self).pointee
                let mlen = Int(hdr.ifm_msglen)
                if mlen <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nb = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &nb) != nil {
                        out.append(RawCounters(name: String(cString: nb), flags: UInt32(bitPattern: m.ifm_flags),
                                               rx: m.ifm_data.ifi_ibytes, tx: m.ifm_data.ifi_obytes))
                    }
                }
                off += mlen
            }
        }
        return out
    }

    private struct Addrs { var v4: [String] = []; var v6: [String] = []; var mac: String? }

    private func readAddresses() -> [String: Addrs] {
        var res: [String: Addrs] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return res }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            var a = res[name] ?? Addrs()
            switch Int32(sa.pointee.sa_family) {
            case AF_INET, AF_INET6:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    var s = String(cString: host)
                    if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
                    if Int32(sa.pointee.sa_family) == AF_INET { a.v4.append(s) } else { a.v6.append(s) }
                }
            case AF_LINK:
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    if dl.pointee.sdl_alen == 6 {
                        let nlen = Int(dl.pointee.sdl_nlen)
                        let bytes: [UInt8] = withUnsafePointer(to: &dl.pointee.sdl_data) {
                            $0.withMemoryRebound(to: UInt8.self, capacity: 12 + nlen) { b in (0..<6).map { b[nlen + $0] } }
                        }
                        a.mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                }
            default: break
            }
            res[name] = a
        }
        return res
    }

    // MARK: interface names

    private func refreshMeta() {
        var m: [String: (name: String, kind: InterfaceKind)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
                let disp = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
                let type = (SCNetworkInterfaceGetInterfaceType(i) as String?) ?? ""
                var kind: InterfaceKind = .other
                if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = .wifi }
                else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                    kind = disp.lowercased().contains("thunderbolt") ? .thunderbolt : .ethernet
                } else if type == "Bridge" { kind = .thunderbolt }
                else if type == (kSCNetworkInterfaceTypeL2TP as String) || type == (kSCNetworkInterfaceTypePPP as String)
                            || type == (kSCNetworkInterfaceTypeIPSec as String) || type == "VPN" { kind = .vpn }
                m[bsd] = (disp == "Wi-Fi" ? "Wi\u{2011}Fi" : disp, kind)
            }
        }
        ifaceMeta = m
    }

    // MARK: Wi-Fi

    private func readWiFi() -> WiFiInfo? {
        if wifiClient == nil { wifiClient = CWWiFiClient.shared() }
        guard let itf = wifiClient?.interface(), itf.powerOn(), itf.rssiValue() != 0 || itf.ssid() != nil || itf.wlanChannel() != nil else {
            return nil
        }
        var w = WiFiInfo()
        w.ssid = itf.ssid()
        w.rssi = itf.rssiValue()
        w.noise = itf.noiseMeasurement()
        w.txRateMbps = itf.transmitRate()
        if let ch = itf.wlanChannel() {
            let band: String
            switch ch.channelBand {
            case .band2GHz: band = "2.4 GHz"
            case .band5GHz: band = "5 GHz"
            case .band6GHz: band = "6 GHz"
            default: band = "?"
            }
            let width: String
            switch ch.channelWidth {
            case .width20MHz: width = "20 MHz"
            case .width40MHz: width = "40 MHz"
            case .width80MHz: width = "80 MHz"
            case .width160MHz: width = "160 MHz"
            default: width = ""
            }
            w.channel = "\(ch.channelNumber) (\(band)\(width.isEmpty ? "" : ", " + width))"
        }
        switch itf.activePHYMode() {
        case .mode11a: w.phyMode = "802.11a"
        case .mode11b: w.phyMode = "802.11b"
        case .mode11g: w.phyMode = "802.11g"
        case .mode11n: w.phyMode = "802.11n"
        case .mode11ac: w.phyMode = "802.11ac"
        case .mode11ax: w.phyMode = "802.11ax"
        default:
            // 802.11be (Wi-Fi 7) maps to rawValue 6 on newer SDKs
            w.phyMode = itf.activePHYMode().rawValue == 6 ? "802.11be" : nil
        }
        switch itf.security() {
        case .none: w.security = "None"
        case .WEP: w.security = "WEP"
        case .wpaPersonal, .wpaPersonalMixed: w.security = "WPA Personal"
        case .wpa2Personal: w.security = "WPA2 Personal"
        case .personal: w.security = "Personal"
        case .dynamicWEP: w.security = "Dynamic WEP"
        case .wpaEnterprise, .wpaEnterpriseMixed: w.security = "WPA Enterprise"
        case .wpa2Enterprise: w.security = "WPA2 Enterprise"
        case .enterprise: w.security = "Enterprise"
        case .wpa3Personal: w.security = "WPA3 Personal"
        case .wpa3Enterprise: w.security = "WPA3 Enterprise"
        case .wpa3Transition: w.security = "WPA3 Transition"
        default: w.security = nil
        }
        return w
    }
}

/// Fetches the public IP at most every 5 minutes (or on primary-interface change),
/// only when the `fetchPublicIP` default is true. Never blocks the caller.
final class PublicIPFetcher: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var lastFetch = Date.distantPast
    private var lastPrimary: String?
    private var inFlight = false

    func current(primary: String?) -> String? {
        guard UserDefaults.standard.bool(forKey: "fetchPublicIP") else {
            lock.lock(); value = nil; lastFetch = .distantPast; lock.unlock()
            return nil
        }
        lock.lock()
        let changed = primary != lastPrimary
        lastPrimary = primary
        if changed { value = nil }   // a different network has a different public IP; don't show the old one
        let due = changed || Date().timeIntervalSince(lastFetch) > 300
        let start = due && !inFlight && primary != nil
        if start { inFlight = true; lastFetch = Date() }
        let v = value
        lock.unlock()
        if start { fetch() }
        return v
    }

    private func fetch() {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            let s = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lock.lock()
            if let s, !s.isEmpty, s.count < 46, s.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) {
                self.value = s
            } else {
                // Offline / captive portal: retry in ~30 s rather than waiting the full 5 minutes.
                self.lastFetch = Date().addingTimeInterval(-270)
            }
            self.inFlight = false
            self.lock.unlock()
        }.resume()
    }
}
