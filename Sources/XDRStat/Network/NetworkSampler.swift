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
    private var addrs: [String: Addrs] = [:]
    private var addrsTick = -1000
    private var primary: String?, gateway: String?, dns: [String] = []
    private var globalTick = -1000
    private var routeBuf: [UInt8] = []
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
        // Addresses, router and DNS only show in the panel. While it's closed they're refreshed every 5 s:
        // addresses decide which interfaces count, and the public IP lookup watches the primary interface.
        if detailed || tick - globalTick >= 5 { readGlobal(); globalTick = tick }
        if detailed || tick - addrsTick >= 5 { addrs = readAddresses(); addrsTick = tick }
        snap.gateway = gateway
        snap.dnsServers = dns

        let counters = readCounters(withMAC: detailed)

        var infos: [NetworkInterfaceInfo] = []
        var seen = Set<String>()
        for c in counters {
            let name = c.name
            seen.insert(name)
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
                macAddress: c.mac, downBytesPerSec: down, upBytesPerSec: up,
                totalDown: c.rx, totalUp: c.tx))
        }
        last = last.filter { seen.contains($0.key) }
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

        // Wi-Fi: CoreWLAN is the costliest call here and only the Network panel shows it. Dropped while
        // the panel is closed so it never reopens showing a stale network.
        if !detailed { cachedWiFi = nil }
        else if tick % 2 == 1 || cachedWiFi == nil { cachedWiFi = readWiFi() }
        snap.wifi = cachedWiFi

        snap.publicIPv4 = ip.current(primary: primary)
        return snap
    }

    private func readGlobal() {
        guard let s = dynStore() else { return }
        let v4 = SCDynamicStoreCopyValue(s, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        primary = v4?["PrimaryInterface"] as? String
        gateway = v4?["Router"] as? String
        let d = SCDynamicStoreCopyValue(s, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        dns = d?["ServerAddresses"] as? [String] ?? []
    }

    // MARK: counters (64-bit via NET_RT_IFLIST2)

    private struct RawCounters { var name: String; var flags: UInt32; var rx: UInt64; var tx: UInt64; var mac: String? }

    private func readCounters(withMAC: Bool) -> [RawCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // Reuse the buffer from last time; grow it (with headroom, as the table can grow between the size
        // query and the read when a VPN comes up or an adapter is plugged in) only when it's too small.
        var len = 0
        var ok = false
        for _ in 0..<3 {
            len = routeBuf.count
            if len > 0 {
                if sysctl(&mib, UInt32(mib.count), &routeBuf, &len, nil, 0) == 0 { ok = true; break }
                if errno != ENOMEM { return [] }
            }
            var need = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &need, nil, 0) == 0, need > 0 else { return [] }
            routeBuf = [UInt8](repeating: 0, count: need + need / 8 + 512)
        }
        guard ok else { return [] }
        var out: [RawCounters] = []
        routeBuf.withUnsafeBytes { raw in
            let hdrSize = MemoryLayout<if_msghdr>.size, hdr2Size = MemoryLayout<if_msghdr2>.size
            var off = 0
            while off + hdrSize <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let mlen = Int(hdr.ifm_msglen)
                guard mlen > 0, off + mlen <= len else { break }
                defer { off += mlen }
                guard Int32(hdr.ifm_type) == RTM_IFINFO2, mlen >= hdr2Size else { continue }
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                // The interface's link-level sockaddr_dl follows the header: name, then MAC. Reading it
                // here avoids if_indextoname(), which walks every interface's addresses per call.
                var name = "", mac: String?
                let sdl = off + hdr2Size, end = off + mlen
                if (m.ifm_addrs & RTA_IFP) != 0, sdl + 8 <= end, Int32(raw[sdl + 1]) == AF_LINK {
                    let nlen = Int(raw[sdl + 5]), alen = Int(raw[sdl + 6]), data = sdl + 8
                    if nlen > 0, data + nlen <= end {
                        name = String(decoding: UnsafeRawBufferPointer(rebasing: raw[data..<(data + nlen)]), as: UTF8.self)
                    }
                    if withMAC, alen == 6, data + nlen + 6 <= end {
                        mac = Self.hex(UnsafeRawBufferPointer(rebasing: raw[(data + nlen)..<(data + nlen + 6)]))
                    }
                }
                if name.isEmpty {
                    var nb = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &nb) != nil { name = String(cString: nb) }
                }
                guard !name.isEmpty else { continue }
                out.append(RawCounters(name: name, flags: UInt32(bitPattern: m.ifm_flags),
                                       rx: m.ifm_data.ifi_ibytes, tx: m.ifm_data.ifi_obytes, mac: mac))
            }
        }
        return out
    }

    private static func hex(_ bytes: UnsafeRawBufferPointer) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var s = [UInt8]()
        s.reserveCapacity(bytes.count * 3)
        for (i, b) in bytes.enumerated() {
            if i > 0 { s.append(UInt8(ascii: ":")) }
            s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 0xf)])
        }
        return String(decoding: s, as: UTF8.self)
    }

    private struct Addrs { var v4: [String] = []; var v6: [String] = [] }

    private func readAddresses() -> [String: Addrs] {
        var res: [String: Addrs] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return res }
        defer { freeifaddrs(head) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr else { continue }
            // inet_ntop, not getnameinfo: the latter appends "%scope" to link-local addresses by looking
            // the interface up by index (another full interface walk per address).
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil {
                    res[String(cString: cur.pointee.ifa_name), default: Addrs()].v4.append(String(cString: buf))
                }
            case AF_INET6:
                var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                withUnsafeMutableBytes(of: &a) { b in
                    // The kernel embeds the scope id in bytes 2-3 of link-local addresses (KAME); clear it.
                    if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { b[2] = 0; b[3] = 0 }
                }
                if inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil {
                    res[String(cString: cur.pointee.ifa_name), default: Addrs()].v6.append(String(cString: buf))
                }
            default: break
            }
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
