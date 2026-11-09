// Manual "Check for Updates" (Settings → About). OWNER: lead.
// Only runs when the user clicks: the app makes no network requests of its own otherwise.
import Foundation

enum UpdateCheck {
    static let releasesAPI = URL(string: "https://api.github.com/repos/karimbacchus/xdrstat/releases/latest")!
    static let website = URL(string: "https://xdrstat.com")!
    static let repository = URL(string: "https://github.com/karimbacchus/xdrstat")!

    enum State: Equatable {
        case idle, checking, upToDate
        case available(version: String, page: URL)
        case failed
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The newest published release, or nil if GitHub can't be reached.
    static func latest() async -> (version: String, page: URL)? {
        var req = URLRequest(url: releasesAPI, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? website
        return (version, page)
    }

    static func check() async -> State {
        guard let l = await latest() else { return .failed }
        return isNewer(l.version, than: currentVersion) ? .available(version: l.version, page: l.page) : .upToDate
    }

    /// Numeric dotted-version comparison: "1.0.10" > "1.0.9", "1.1" > "1.0.1".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
