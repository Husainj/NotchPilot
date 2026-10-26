import Foundation

/// What a usage key refers to. Keys are stored as `app:<bundle id>` or `web:<domain>`.
enum UsageKey {
    static func app(_ bundleID: String) -> String { "app:" + bundleID }
    static func web(_ domain: String) -> String { "web:" + domain }

    static func bundleID(_ key: String) -> String? {
        key.hasPrefix("app:") ? String(key.dropFirst(4)) : nil
    }

    static func domain(_ key: String) -> String? {
        key.hasPrefix("web:") ? String(key.dropFirst(4)) : nil
    }

    /// The site's domain for an http(s) URL, without `www.` / `m.` / `mobile.`.
    /// Local pages (localhost, IP addresses, file://) return nil.
    static func normalizedDomain(fromURL string: String) -> String? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), host.contains(".")
        else { return nil }
        if host == "localhost" || host.hasSuffix(".local") || host.contains(":")
            || host.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
            break
        }
        return host
    }
}

/// Default lists of distracting sites and apps, and matching against them.
struct Categories: Equatable, Sendable {
    var sites: [String]
    var apps: [String]

    static let defaultSites = [
        "instagram.com", "youtube.com", "x.com", "twitter.com", "reddit.com", "facebook.com",
        "tiktok.com", "netflix.com", "twitch.tv", "snapchat.com", "pinterest.com",
        "primevideo.com", "hotstar.com", "9gag.com",
    ]
    static let defaultApps = ["com.hnc.Discord", "com.valvesoftware.steam", "com.apple.TV"]

    /// Sites people watch without touching the keyboard, so idle time still counts.
    static let videoSites: Set<String> = [
        "youtube.com", "netflix.com", "twitch.tv", "primevideo.com", "hotstar.com", "disneyplus.com", "hulu.com",
    ]

    static let standard = Categories(sites: defaultSites, apps: defaultApps)

    func isDistracting(_ key: String) -> Bool {
        if let domain = UsageKey.domain(key) {
            return sites.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
        if let bundleID = UsageKey.bundleID(key) { return apps.contains(bundleID) }
        return false
    }

    static func isVideo(_ key: String) -> Bool {
        guard let domain = UsageKey.domain(key) else { return false }
        return videoSites.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// The list entry that makes `key` distracting, so it can be removed.
    func matchingEntry(for key: String) -> String? {
        if let domain = UsageKey.domain(key) {
            return sites.first { domain == $0 || domain.hasSuffix("." + $0) }
        }
        if let bundleID = UsageKey.bundleID(key), apps.contains(bundleID) { return bundleID }
        return nil
    }
}
