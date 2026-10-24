import AppKit
import Observation

/// A calendar event a module can offer a "Join" button for.
public struct JoinableMeeting: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let joinURL: URL?

    public init(id: String, title: String, start: Date, end: Date, joinURL: URL?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.joinURL = joinURL
    }
}

/// Finds video-call links in calendar events and opens them in the native app when installed.
public enum MeetingLink {
    public enum Service: String, Sendable {
        case zoom, meet, teams, webex, facetime, other

        public var name: String {
            switch self {
            case .zoom: "Zoom"
            case .meet: "Google Meet"
            case .teams: "Teams"
            case .webex: "Webex"
            case .facetime: "FaceTime"
            case .other: "Call"
            }
        }
    }

    private static let hosts: [(suffix: String, pathPrefix: String?, service: Service)] = [
        ("zoom.us", "/j/", .zoom), ("zoom.us", "/my/", .zoom), ("zoom.us", "/w/", .zoom),
        ("zoomgov.com", "/j/", .zoom),
        ("meet.google.com", nil, .meet),
        ("teams.microsoft.com", "/l/meetup-join", .teams), ("teams.microsoft.com", "/meet/", .teams),
        ("teams.live.com", "/meet", .teams),
        ("webex.com", nil, .webex),
        ("facetime.apple.com", "/join", .facetime),
        ("whereby.com", nil, .other), ("meet.jit.si", nil, .other), ("around.co", nil, .other),
        ("chime.aws", nil, .other), ("gather.town", nil, .other), ("discord.gg", nil, .other),
    ]

    public static func service(for url: URL) -> Service? {
        guard let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true else { return nil }
        for entry in hosts where host == entry.suffix || host.hasSuffix("." + entry.suffix) {
            if let prefix = entry.pathPrefix, !url.path.hasPrefix(prefix) { continue }
            if entry.service == .meet, url.path.count < 4 { continue } // bare meet.google.com
            return entry.service
        }
        return nil
    }

    /// The first call link in the event's URL, location or notes.
    public static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, service(for: url) != nil { return url }
        let text = [location, notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let link = match.url, service(for: link) != nil { return link }
        }
        return nil
    }

    /// Zoom and Teams links open straight in their apps when installed.
    public static func appURL(for url: URL, isInstalled: (String) -> Bool = Self.isInstalled) -> URL {
        switch service(for: url) {
        case .zoom:
            guard isInstalled("us.zoom.xos") else { return url }
            let parts = url.path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "j" else { return url }
            var components = URLComponents()
            components.scheme = "zoommtg"
            components.host = url.host
            components.path = "/join"
            var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[1]))]
            if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
                items.append(URLQueryItem(name: "pwd", value: pwd))
            }
            components.queryItems = items
            return components.url ?? url
        case .teams:
            guard isInstalled("com.microsoft.teams2") || isInstalled("com.microsoft.teams") else { return url }
            let rest = url.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            guard let slash = rest.firstIndex(of: "/") else { return url }
            return URL(string: "msteams:" + rest[slash...]) ?? url
        default:
            return url
        }
    }

    public static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    @MainActor
    public static func join(_ url: URL) {
        NSWorkspace.shared.open(appURL(for: url))
    }
}

/// Whether the user is on a call, shared so other modules can stay quiet.
@MainActor
@Observable
public final class CallStatus {
    public static let shared = CallStatus()

    public var isInCall = false
    /// Set by the meeting module from its settings.
    public var silenceSoundsDuringCalls = true

    public var shouldSilenceSounds: Bool { isInCall && silenceSoundsDuringCalls }
}
