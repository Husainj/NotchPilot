import AppKit
import NotchShell
import SwiftUI

struct MeetingView: View {
    let module: MeetingModule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MicCard(module: module)
            CallCard(module: module)
            MeetingsCard(module: module)
        }
    }
}

private struct MeetingCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MicCard: View {
    let module: MeetingModule

    var body: some View {
        let mic = module.mic
        MeetingCard(title: "Microphone") {
            HStack(spacing: 12) {
                Button { module.toggleMute() } label: {
                    Image(systemName: mic.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .foregroundStyle(mic.isMuted ? .white : .black)
                        .background(mic.isMuted ? Color.red : Color.white, in: Circle())
                }
                .buttonStyle(.island)
                .disabled(!mic.canMute)
                .help(mic.isMuted ? "Unmute" : "Mute for every app")
                VStack(alignment: .leading, spacing: 3) {
                    Text(mic.isMuted ? "Muted" : "Live")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mic.isMuted ? .red : .white)
                    Text(mic.deviceName)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    if let combo = module.hotKey {
                        Text(combo.displayString)
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            if !mic.canMute {
                Text("macOS can't mute this microphone. Use the call app's mute button.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct CallCard: View {
    let module: MeetingModule

    var body: some View {
        let clients = module.mic.clients
        MeetingCard(title: module.tracker.isInCall ? "On a call" : "Mic & camera") {
            if let start = module.tracker.callStart {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingModule.clock(context.date.timeIntervalSince(start)))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if clients.isEmpty && !module.mic.isInUse {
                    StatusLine(symbol: "mic", text: "No app is using the mic", active: false)
                } else if clients.isEmpty {
                    StatusLine(symbol: "mic.fill", text: "Mic in use", active: true)
                }
                ForEach(clients) { client in
                    HStack(spacing: 6) {
                        AppIcon(pid: client.pid, bundleID: client.bundleID)
                        Text("\(client.name) is using the mic")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSRunningApplication(processIdentifier: client.pid)?.activate()
                    }
                }
                StatusLine(symbol: module.camera.isInUse ? "video.fill" : "video",
                           text: module.camera.isInUse ? "Camera is on" : "Camera is off",
                           active: module.camera.isInUse)
            }
        }
    }
}

private struct StatusLine: View {
    let symbol: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(active ? .orange : .white.opacity(0.4))
            Text(text)
                .foregroundStyle(active ? .white : .white.opacity(0.5))
        }
        .font(.system(size: 11))
    }
}

private struct AppIcon: View {
    let pid: pid_t
    let bundleID: String

    var body: some View {
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        if let icon {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.fill").frame(width: 16, height: 16)
        }
    }
}

private struct MeetingsCard: View {
    let module: MeetingModule
    @Environment(\.notchAccent) private var accent

    var body: some View {
        let now = Date()
        let today = module.meetings.filter { Calendar.current.isDateInToday($0.start) || $0.start < now }
        MeetingCard(title: "Today's meetings") {
            if today.isEmpty {
                Text("No more meetings today. Calendar access is set up in the Calendar tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(today.prefix(6)) { meeting in
                            MeetingRow(meeting: meeting)
                        }
                    }
                }
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: JoinableMeeting
    @Environment(\.notchAccent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let live = meeting.start <= now && meeting.end > now
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(live ? "Now · until \(meeting.end.formatted(date: .omitted, time: .shortened))"
                         : Self.startsIn(meeting.start, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(live ? accent : .white.opacity(0.5))
                }
                Spacer(minLength: 4)
                if let url = meeting.joinURL {
                    Button { MeetingLink.join(url) } label: {
                        Text("Join")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .foregroundStyle(.black)
                            .background(accent, in: Capsule())
                    }
                    .buttonStyle(.island)
                    .help("Join on \(MeetingLink.service(for: url)?.name ?? "the call")")
                }
            }
        }
    }

    static func startsIn(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 60 { return "in \(minutes)m · \(start.formatted(date: .omitted, time: .shortened))" }
        return start.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Settings

struct MeetingSettingsView: View {
    @Bindable var module: MeetingModule

    var body: some View {
        Form {
            Section("Microphone") {
                LabeledContent("Mute / unmute everywhere") {
                    HotKeyRecorder(combo: $module.hotKey)
                }
                Toggle("Unmute automatically when a call ends", isOn: $module.autoUnmute)
                Text("\(AppInfo.name) mutes the microphone itself, so it works in every app. Call apps like Zoom won't show their own mute button as pressed, but they receive silence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("During calls") {
                Toggle("Show mic and camera status beside the notch", isOn: $module.showIndicator)
                Toggle("Silence \(AppInfo.name)'s sounds", isOn: $module.silenceSounds)
                Picker("When a call starts, run Shortcut", selection: $module.startShortcut) {
                    Text("None").tag("")
                    ForEach(shortcutChoices(module.startShortcut), id: \.self) { Text($0).tag($0) }
                }
                Picker("When it ends, run Shortcut", selection: $module.endShortcut) {
                    Text("None").tag("")
                    ForEach(shortcutChoices(module.endShortcut), id: \.self) { Text($0).tag($0) }
                }
                Text("Tip: make Shortcuts that turn Do Not Disturb on and off (Set Focus action) and pick them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { module.loadShortcuts() }
    }

    /// Keeps a saved choice selectable even if Shortcuts hasn't listed yet.
    private func shortcutChoices(_ current: String) -> [String] {
        var names = module.availableShortcuts
        if !current.isEmpty, !names.contains(current) { names.insert(current, at: 0) }
        return names
    }
}
