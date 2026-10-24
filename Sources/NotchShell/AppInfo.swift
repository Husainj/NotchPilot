import Foundation

/// The app's public name and links. Change these when renaming or forking.
/// See "Renaming" in README.md for the places outside Swift (Info.plist, scripts, site).
public enum AppInfo {
    public static let name = "NotchPilot"
    public static let author = "husain_j53" // X handle, without "@"
    public static let githubRepo = URL(string: "https://github.com/Husainj/notchpilot")!
    public static let website = URL(string: "https://notchpilot.husainjhalod.me/")!

    public static var twitter: URL { URL(string: "https://x.com/\(author)")! }
    public static var issues: URL { githubRepo.appendingPathComponent("issues/new/choose") }
    public static var releases: URL { githubRepo.appendingPathComponent("releases") }

    public static func releaseNotes(for version: String) -> URL {
        githubRepo.appendingPathComponent("releases/tag/v\(version)")
    }

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
