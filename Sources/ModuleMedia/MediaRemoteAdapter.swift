import AppKit

/// Now-playing info for *any* app (browsers, Podcasts, VLC, …).
///
/// Since macOS 15.4 only Apple-entitled processes may read MediaRemote's
/// now-playing info. The bundled mediaremote-adapter (BSD-3, see
/// Vendor/mediaremote-adapter) runs inside `/usr/bin/perl`, which has that
/// entitlement, and streams the state as JSON lines that we parse here.
struct NowPlayingInfo: Equatable, Sendable {
    var bundleIdentifier: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    /// When `elapsed` was measured.
    var timestamp: Date
    var isPlaying: Bool
    var artworkData: Data?
}

final class MediaRemoteAdapter: @unchecked Sendable {
    /// Adapter script + framework inside NotchPilot.app. Debug builds run from Xcode
    /// (no app bundle) use the copies in the repo instead (`make adapter`).
    static let resources: (script: URL, framework: URL)? = {
        let fm = FileManager.default
        if let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
           let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
           fm.fileExists(atPath: framework.path) {
            return (script, framework)
        }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl")
        let framework = root.appendingPathComponent("build/MediaRemoteAdapter.framework")
        if fm.fileExists(atPath: script.path), fm.fileExists(atPath: framework.path) {
            return (script, framework)
        }
        #endif
        return nil
    }()

    static var isAvailable: Bool { resources != nil }

    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    /// Last full payload, with diffs merged in.
    private var state: [String: Any] = [:]
    private var isStopped = true
    private let onUpdate: @Sendable (NowPlayingInfo?) -> Void

    /// `onUpdate` is called on a background queue.
    init(onUpdate: @escaping @Sendable (NowPlayingInfo?) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        lock.withLock { isStopped = false }
        launch()
    }

    func stop() {
        let running = lock.withLock { () -> Process? in
            isStopped = true
            defer { process = nil }
            return process
        }
        running?.terminationHandler = nil
        running?.terminate()
    }

    /// Seeks the current player (seconds).
    static func seek(to seconds: TimeInterval) {
        run(["seek", String(Int64(seconds * 1_000_000))])
    }

    // MARK: - Process

    private func launch() {
        guard let resources = Self.resources else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.script.path, resources.framework.path,
                             "stream", "--micros", "--debounce=100", "--allow-missing-title"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.relaunchAfterCrash()
        }
        lock.withLock {
            buffer.removeAll()
            state.removeAll()
            self.process = process
        }
        do {
            try process.run()
        } catch {
            lock.withLock { self.process = nil }
        }
    }

    private func relaunchAfterCrash() {
        guard !lock.withLock({ isStopped }) else { return }
        onUpdate(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.lock.withLock({ self.isStopped }) else { return }
            self.launch()
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines {
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        let info: NowPlayingInfo? = lock.withLock {
            if message["diff"] as? Bool == true {
                for (key, value) in payload {
                    if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
                }
            } else {
                state = payload
            }
            return Self.parse(state)
        }
        onUpdate(info)
    }

    static func parse(_ payload: [String: Any]) -> NowPlayingInfo? {
        // Browsers play media in helper processes; prefer the app the user sees.
        let pid = (payload["processIdentifier"] as? NSNumber)?.int32Value
        let bundleID = payload["parentApplicationBundleIdentifier"] as? String
            ?? payload["bundleIdentifier"] as? String
            ?? pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            ?? ""
        // Empty payload = nothing is playing.
        guard pid != nil || !bundleID.isEmpty else { return nil }
        // Untagged audio (e.g. a local file) has no title: show the app's name instead.
        let title = (payload["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? appName(for: bundleID)
        func seconds(_ key: String) -> TimeInterval {
            (payload[key] as? NSNumber).map { $0.doubleValue / 1_000_000 } ?? 0
        }
        let timestamp = (payload["timestampEpochMicros"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1_000_000) } ?? Date()
        return NowPlayingInfo(
            bundleIdentifier: bundleID,
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            duration: seconds("durationMicros"),
            elapsed: seconds("elapsedTimeMicros"),
            timestamp: timestamp,
            isPlaying: payload["playing"] as? Bool ?? false,
            artworkData: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
        )
    }

    static func appName(for bundleID: String) -> String {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "Now Playing" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Runs a one-off adapter command (e.g. seek) in the background.
    private static func run(_ arguments: [String]) {
        guard let resources else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.script.path, resources.framework.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
