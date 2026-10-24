import AppKit
import Observation

/// Players the AppleScript fallback can read track info from.
enum MediaPlayer: String, CaseIterable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var scriptName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    /// Distributed notification the player posts on every track/state change.
    var notificationName: Notification.Name {
        switch self {
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }
}

struct Track: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
}

/// Tracks what's playing and sends playback commands.
///
/// Primary source: the bundled MediaRemote adapter, which sees every app
/// (browsers, Podcasts, local files…). Fallback when the adapter isn't
/// bundled (e.g. running from Xcode): AppleScript for Music and Spotify.
@MainActor
@Observable
final class NowPlayingService {
    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// App that owns playback, e.g. "com.google.Chrome".
    private(set) var sourceBundleID: String?
    /// Position at `positionDate`; the UI extrapolates while playing.
    private(set) var position: TimeInterval = 0
    private(set) var positionDate = Date()

    @ObservationIgnored private var player: MediaPlayer?
    @ObservationIgnored private var adapter: MediaRemoteAdapter?
    @ObservationIgnored private let scripts = ScriptRunner()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var artworkKey: String?

    var sourceAppIcon: NSImage? {
        guard let id = sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var sourceAppName: String? {
        sourceBundleID.map(MediaRemoteAdapter.appName(for:))
    }

    func start() {
        if MediaRemoteAdapter.isAvailable {
            let adapter = MediaRemoteAdapter { [weak self] info in
                Task { @MainActor in self?.apply(info) }
            }
            adapter.start()
            self.adapter = adapter
        } else {
            startScriptingFallback()
        }
    }

    func stop() {
        adapter?.stop()
        adapter = nil
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers.removeAll()
        syncTask?.cancel()
    }

    func currentPosition(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let duration = track?.duration ?? 0
        let now = position + date.timeIntervalSince(positionDate)
        return duration > 0 ? min(now, duration) : now
    }

    // MARK: - Commands

    func togglePlayPause() { send("playpause", fallback: .togglePlayPause) }
    func nextTrack() { send("next track", fallback: .nextTrack) }
    func previousTrack() { send("previous track", fallback: .previousTrack) }

    func seek(to seconds: TimeInterval) {
        position = seconds
        positionDate = Date()
        if adapter != nil {
            MediaRemoteAdapter.seek(to: seconds)
        } else if let player {
            Task { await scripts.execute("tell application \"\(player.scriptName)\" to set player position to \(seconds)") }
        }
    }

    func openPlayer() {
        guard let id = sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func send(_ command: String, fallback: MediaRemote.Command) {
        guard adapter == nil, let player, player.isRunning else {
            // System-wide command: reaches whichever app owns playback.
            MediaRemote.send(fallback)
            return
        }
        Task {
            await scripts.execute("tell application \"\(player.scriptName)\" to \(command)")
            refresh(preferring: player)
        }
    }

    // MARK: - Adapter source

    private func apply(_ info: NowPlayingInfo?) {
        guard let info else {
            clear()
            return
        }
        sourceBundleID = info.bundleIdentifier
        track = Track(title: info.title, artist: info.artist, album: info.album, duration: info.duration)
        isPlaying = info.isPlaying
        position = info.elapsed + (info.isPlaying ? max(Date().timeIntervalSince(info.timestamp), 0) : 0)
        positionDate = Date()
        let key = "\(info.bundleIdentifier)|\(info.title)|\(info.album)|\(info.artworkData?.count ?? 0)"
        if key != artworkKey {
            artworkKey = key
            artwork = info.artworkData.flatMap(NSImage.init(data:))
        }
    }

    private func clear() {
        player = nil
        sourceBundleID = nil
        track = nil
        isPlaying = false
        artwork = nil
        artworkKey = nil
    }

    // MARK: - AppleScript fallback (Music & Spotify only)

    private func startScriptingFallback() {
        let center = DistributedNotificationCenter.default()
        for player in MediaPlayer.allCases {
            observers.append(center.addObserver(forName: player.notificationName, object: nil, queue: .main) { [weak self] note in
                let state = note.userInfo?["Player State"] as? String
                MainActor.assumeIsolated {
                    // A player posts "Stopped" while quitting; scripting it then would relaunch it.
                    if state == "Stopped" {
                        self?.refresh(preferring: nil, excluding: player)
                    } else {
                        self?.refresh(preferring: player)
                    }
                }
            })
        }
        refresh(preferring: nil)
        // Periodic resync keeps the scrubber honest after seeks made in the player itself.
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isPlaying else { continue }
                self.refresh(preferring: self.player)
            }
        }
    }

    /// Re-reads state from the running players, preferring one that is playing.
    private func refresh(preferring preferred: MediaPlayer?, excluding excluded: MediaPlayer? = nil) {
        Task {
            var candidates = MediaPlayer.allCases.filter { $0.isRunning && $0 != excluded }
            if let preferred, let i = candidates.firstIndex(of: preferred) {
                candidates.swapAt(0, i)
            }
            var best: (MediaPlayer, PlayerSnapshot)?
            for candidate in candidates {
                guard let snap = await scripts.snapshot(of: candidate) else { continue }
                if snap.isPlaying { best = (candidate, snap); break }
                if best == nil { best = (candidate, snap) }
            }
            applyScripted(best)
        }
    }

    private func applyScripted(_ result: (MediaPlayer, PlayerSnapshot)?) {
        guard let (player, snap) = result, let track = snap.track else {
            clear()
            return
        }
        self.player = player
        sourceBundleID = player.rawValue
        self.track = track
        isPlaying = snap.isPlaying
        position = snap.position
        positionDate = Date()

        let key = "\(player.rawValue)|\(track.title)|\(track.album)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        Task {
            let image = await loadArtwork(for: player)
            if artworkKey == key { artwork = image }
        }
    }

    private func loadArtwork(for player: MediaPlayer) async -> NSImage? {
        switch player {
        case .music:
            guard let data = await scripts.musicArtworkData() else { return nil }
            return NSImage(data: data)
        case .spotify:
            guard let url = await scripts.spotifyArtworkURL(),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
    }
}

struct PlayerSnapshot: Sendable {
    var track: Track?
    var isPlaying: Bool
    var position: TimeInterval
}

/// Runs AppleScript off the main thread, one script at a time.
actor ScriptRunner {
    /// Runs a script for its side effect.
    func execute(_ source: String) {
        _ = run(source)
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    func snapshot(of player: MediaPlayer) -> PlayerSnapshot? {
        // Never target a player that isn't running: `tell application` would launch it.
        guard player.isRunning else { return nil }
        let durationExpr = player == .spotify ? "(duration of current track) / 1000" : "duration of current track"
        let source = """
        tell application "\(player.scriptName)"
            set st to (player state as string)
            if st is "stopped" then return {st, "", "", "", 0, 0}
            return {st, name of current track, artist of current track, album of current track, \(durationExpr), player position}
        end tell
        """
        guard let result = run(source), result.numberOfItems >= 6 else { return nil }
        let state = result.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", let title = result.atIndex(2)?.stringValue, !title.isEmpty else {
            return PlayerSnapshot(track: nil, isPlaying: false, position: 0)
        }
        let track = Track(
            title: title,
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: Self.number(result.atIndex(5))
        )
        return PlayerSnapshot(track: track, isPlaying: state == "playing", position: Self.number(result.atIndex(6)))
    }

    func musicArtworkData() -> Data? {
        guard MediaPlayer.music.isRunning else { return nil }
        let result = run("tell application \"Music\" to get raw data of artwork 1 of current track")
        return result?.data
    }

    func spotifyArtworkURL() -> URL? {
        guard MediaPlayer.spotify.isRunning,
              let string = run("tell application \"Spotify\" to get artwork url of current track")?.stringValue
        else { return nil }
        return URL(string: string)
    }

    private static func number(_ descriptor: NSAppleEventDescriptor?) -> Double {
        descriptor?.doubleValue ?? 0
    }
}
