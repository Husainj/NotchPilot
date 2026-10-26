import AppKit

/// Reads the active tab's URL from common browsers via AppleScript.
/// macOS asks once per browser ("NotchPilot wants to control Safari");
/// if the user declines, that browser is tracked as a plain app.
actor BrowserURLReader {
    enum Family: Sendable { case safari, chromium }

    static let browsers: [String: Family] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "company.thebrowser.Browser": .chromium, // Arc
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.operasoftware.Opera": .chromium,
    ]

    static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    /// The active tab's URL, or nil if unavailable (no window, permission denied, …).
    func activeURL(bundleID: String) -> String? {
        guard let family = Self.browsers[bundleID],
              // `tell application` would launch a browser that isn't running.
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        else { return nil }
        let tab = family == .safari ? "current tab" : "active tab"
        let source = """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return ""
            return URL of \(tab) of front window
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, let url = result?.stringValue, !url.isEmpty else { return nil }
        return url
    }
}
