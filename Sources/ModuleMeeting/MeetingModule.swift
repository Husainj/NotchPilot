import AppKit
import Carbon.HIToolbox
import NotchShell
import SwiftUI

/// Meeting mode: live mic/camera indicator, a system-wide mute hotkey,
/// call detection, and one-click Join for upcoming calendar meetings.
@MainActor
@Observable
public final class MeetingModule: NotchModule {
    public let id = "meeting"
    public let title = "Meeting"
    public let systemImage = "video"

    let mic = MicController()
    let camera = CameraMonitor()
    private(set) var tracker = CallTracker()
    private(set) var availableShortcuts: [String] = []

    var hotKey: HotKeyCombo? {
        didSet {
            HotKeyCombo.store(hotKey, key: "meeting.hotKey", in: .standard)
            registerHotKey()
        }
    }
    var showIndicator: Bool { didSet { save(showIndicator, "meeting.indicator") } }
    var autoUnmute: Bool { didSet { save(autoUnmute, "meeting.autoUnmute") } }
    var silenceSounds: Bool {
        didSet {
            save(silenceSounds, "meeting.silence")
            CallStatus.shared.silenceSoundsDuringCalls = silenceSounds
        }
    }
    var startShortcut: String { didSet { UserDefaults.standard.set(startShortcut, forKey: "meeting.startShortcut") } }
    var endShortcut: String { didSet { UserDefaults.standard.set(endShortcut, forKey: "meeting.endShortcut") } }

    static let defaultHotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), keyLabel: "M")

    @ObservationIgnored private let upcoming: @MainActor () -> [JoinableMeeting]
    @ObservationIgnored private weak var context: NotchContext?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// `meetings` supplies calendar events (from the Calendar module) for the Join list.
    public init(meetings: @escaping @MainActor () -> [JoinableMeeting] = { [] }) {
        upcoming = meetings
        let d = UserDefaults.standard
        d.register(defaults: ["meeting.indicator": true, "meeting.autoUnmute": true, "meeting.silence": true])
        hotKey = d.object(forKey: "meeting.hotKey") == nil
            ? Self.defaultHotKey
            : HotKeyCombo.load(key: "meeting.hotKey", from: d)
        showIndicator = d.bool(forKey: "meeting.indicator")
        autoUnmute = d.bool(forKey: "meeting.autoUnmute")
        silenceSounds = d.bool(forKey: "meeting.silence")
        startShortcut = d.string(forKey: "meeting.startShortcut") ?? ""
        endShortcut = d.string(forKey: "meeting.endShortcut") ?? ""
        CallStatus.shared.silenceSoundsDuringCalls = silenceSounds
    }

    private func save(_ value: Bool, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    public func start(context: NotchContext) {
        self.context = context
        mic.onChange = { [weak self] in self?.evaluate() }
        camera.onChange = { [weak self] in self?.evaluate() }
        mic.start()
        camera.start()
        registerHotKey()
        evaluate()
    }

    public func stop() {
        HotKeyCenter.shared.unregister("meeting")
        tickTask?.cancel()
        mic.stop()
        camera.stop()
        CallStatus.shared.isInCall = false
        context = nil
    }

    private func registerHotKey() {
        guard context != nil else { return }
        HotKeyCenter.shared.register("meeting", combo: hotKey) { [weak self] in self?.toggleMute() }
    }

    var meetings: [JoinableMeeting] { upcoming() }

    // MARK: - Mute

    func toggleMute() {
        guard mic.canMute else {
            flash(symbol: "mic.badge.xmark", text: "Can't mute this mic", color: .orange)
            return
        }
        mic.toggleMute()
        flash(symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill",
              text: mic.isMuted ? "Muted" : "Mic on",
              color: mic.isMuted ? .red : .green)
    }

    private func flash(symbol: String, text: String, color: Color) {
        context?.showTransient(CompactActivity(id: "meeting-mute", priority: 100, sideWidth: 70) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        } trailing: {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }, for: .seconds(1.5))
    }

    // MARK: - Calls

    var callApp: MicClient? { mic.clients.first }

    private func evaluate() {
        let active = mic.isInUse || camera.isInUse
        if let transition = tracker.update(active: active, now: Date()) {
            handle(transition)
        }
        scheduleTick()
    }

    /// Start/end are debounced, so re-check once the pending delay passes.
    private func scheduleTick() {
        tickTask?.cancel()
        guard let deadline = tracker.pendingDeadline else { return }
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0) + 0.1))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func handle(_ transition: CallTracker.Transition) {
        switch transition {
        case .started:
            CallStatus.shared.isInCall = true
            runShortcut(startShortcut)
        case .ended(let duration):
            CallStatus.shared.isInCall = false
            runShortcut(endShortcut)
            let wasMuted = mic.isMuted
            if autoUnmute, wasMuted, mic.canMute { mic.setMuted(false) }
            announceEnd(duration: duration, unmuted: autoUnmute && wasMuted)
        }
    }

    private func announceEnd(duration: TimeInterval, unmuted: Bool) {
        guard duration >= 60 || unmuted else { return }
        let minutes = Int(duration / 60)
        let length = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        context?.showTransient(CompactActivity(id: "meeting-ended", priority: 92, sideWidth: 120) {
            HStack(spacing: 5) {
                Image(systemName: "phone.down.fill").foregroundStyle(.red)
                Text("Call ended").lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
        } trailing: {
            Text(unmuted ? "\(length) · mic unmuted" : length)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        }, for: .seconds(4))
    }

    // MARK: - Shortcuts (e.g. turn on a Focus mode during calls)

    func loadShortcuts() {
        Task {
            let names = await Self.shortcutsCommand(["list"]).split(separator: "\n").map(String.init)
            availableShortcuts = names.sorted()
        }
    }

    private func runShortcut(_ name: String) {
        guard !name.isEmpty else { return }
        Task { _ = await Self.shortcutsCommand(["run", name]) }
    }

    nonisolated private static func shortcutsCommand(_ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - NotchModule

    public var compactActivity: CompactActivity? {
        guard showIndicator else { return nil }
        let muted = mic.isMuted
        if let start = tracker.callStart {
            let cameraOn = camera.isInUse
            return CompactActivity(id: "meeting-call", priority: 60, sideWidth: 58) {
                HStack(spacing: 4) {
                    Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(muted ? .red : .orange)
                    if cameraOn {
                        Image(systemName: "video.fill").foregroundStyle(.green)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
            } trailing: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(start)))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
        }
        if muted {
            // Remind the user they're muted even outside a call.
            return CompactActivity(id: "meeting-muted", priority: 8, sideWidth: 56) {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            } trailing: {
                Text("Muted").font(.system(size: 11, weight: .semibold))
            }
        }
        return nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    public func makeExpandedView() -> AnyView {
        AnyView(MeetingView(module: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(MeetingSettingsView(module: self))
    }
}
