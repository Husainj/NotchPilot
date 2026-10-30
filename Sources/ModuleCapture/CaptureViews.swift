import AVFoundation
import NotchShell
import QuickLookThumbnailing
import SwiftUI

struct CaptureView: View {
    let module: CaptureModule

    var body: some View {
        switch module.machine.phase {
        case .recording, .finishing:
            RecordingControls(module: module)
        case let .countingDown(remaining):
            CountdownView(remaining: remaining) { module.cancelCountdown() }
        case let .saved(item):
            SavedCard(module: module, item: item)
        case .idle:
            if !CapturePermissions.hasScreenAccess {
                PermissionCard()
            } else {
                IdleView(module: module)
            }
        }
    }
}

// MARK: Idle

private struct IdleView: View {
    @Bindable var module: CaptureModule
    @Environment(\.notchAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                ModePicker(mode: $module.mode)
                HStack(spacing: 6) {
                    ToggleChip(title: "System audio", systemImage: module.systemAudio ? "speaker.wave.2.fill" : "speaker.slash",
                               isOn: $module.systemAudio)
                    MicChip(module: module)
                    ToggleChip(title: "3s", systemImage: "timer", isOn: $module.countdown)
                        .help("Count down before recording")
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button { module.toggleRecording() } label: {
                        HStack(spacing: 6) {
                            Circle().fill(.white).frame(width: 9, height: 9)
                            Text("Record").font(.system(size: 12.5, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(module.canRecord ? Color.red : Color.gray.opacity(0.4), in: Capsule())
                    }
                    .buttonStyle(.island)
                    .disabled(!module.canRecord)
                    .help(module.recordHotKey.map { "Start or stop with \($0.displayString)" } ?? "Start recording")

                    ScreenshotButton(module: module)
                }
                if let error = module.errorMessage {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if !module.canRecord {
                    Text("Screen recording needs macOS 15 or later. Screenshots work.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                } else if let hotKey = module.recordHotKey {
                    Text("\(hotKey.displayString) starts and stops recording")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 318, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            RecentsCard(module: module)
        }
        .onAppear { module.refreshRecents() }
    }
}

private struct ModePicker: View {
    @Binding var mode: CaptureMode
    @Environment(\.notchAccent) private var accent

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases) { item in
                Button { mode = item } label: {
                    Label(item.title, systemImage: item.systemImage)
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(mode == item ? .black : .white.opacity(0.75))
                        .background(mode == item ? accent : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.island)
            }
        }
        .padding(3)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

private struct ToggleChip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ChipLabel(title: title, systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.island)
    }
}

private struct ChipLabel: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    @Environment(\.notchAccent) private var accent

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? accent : .white.opacity(0.55))
            .background(isOn ? accent.opacity(0.16) : .white.opacity(0.07), in: Capsule())
    }
}

private struct MicChip: View {
    @Bindable var module: CaptureModule

    var body: some View {
        Menu {
            Toggle("Record microphone", isOn: $module.microphone)
            Divider()
            Picker("Microphone", selection: $module.microphoneID) {
                Text("Default").tag(String?.none)
                ForEach(CapturePermissions.microphones, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(Optional(device.uniqueID))
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(title: "Mic", systemImage: module.microphone ? "mic.fill" : "mic.slash", isOn: module.microphone)
        } primaryAction: {
            module.microphone.toggle()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Click to turn the mic on or off. Hold for the device list.")
    }
}

private struct ScreenshotButton: View {
    @Bindable var module: CaptureModule

    var body: some View {
        Menu {
            Button("Area…") { module.takeScreenshot(.area) }
            Button("Window…") { module.takeScreenshot(.window) }
            Button("Whole screen") { module.takeScreenshot(.screen) }
            Divider()
            Toggle("Copy instead of saving", isOn: $module.copyScreenshots)
        } label: {
            Label("Screenshot", systemImage: "camera.fill")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(.white.opacity(0.9))
                .background(.white.opacity(0.1), in: Capsule())
        } primaryAction: {
            module.takeScreenshot(module.mode)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Click for a screenshot of the chosen mode. Hold for more.")
    }
}

private struct RecentsCard: View {
    let module: CaptureModule

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    NSWorkspace.shared.open(module.recordingsFolder)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.island)
                .help("Open the recordings folder")
            }
            if module.recents.isEmpty {
                Text("Your recordings and screenshots show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(module.recents) { item in
                        RecentTile(module: module, item: item)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct RecentTile: View {
    let module: CaptureModule
    let item: CaptureItem
    @State private var hovering = false

    var body: some View {
        Thumbnail(url: item.url)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(4)
                }
            }
            .overlay {
                if hovering {
                    HStack(spacing: 8) {
                        TileAction(systemImage: "arrow.up.forward.app", help: "Open") { module.open(item) }
                        TileAction(systemImage: "doc.on.doc", help: "Copy") { module.copy(item) }
                        TileAction(systemImage: "trash", help: "Move to Trash") { module.delete(item) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { module.open(item) }
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            .contextMenu {
                Button("Open") { module.open(item) }
                Button("Show in Finder") { module.reveal(item) }
                Button("Copy") { module.copy(item) }
                Divider()
                Button("Move to Trash") { module.delete(item) }
            }
            .help(item.name)
    }
}

private struct TileAction: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.island)
        .help(help)
    }
}

// MARK: Recording

private struct RecordingControls: View {
    let module: CaptureModule
    @Environment(\.notchAccent) private var accent

    var body: some View {
        HStack(spacing: 18) {
            RecordingDot(pulsing: module.machine.isRecording, size: 18)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                if case let .recording(start) = module.machine.phase {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(CaptureFormat.elapsed(context.date.timeIntervalSince(start)))
                            .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                } else {
                    Text("Saving…")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if module.microphone {
                        CaptureGhostButton(title: module.micMuted ? "Unmute mic" : "Mute mic",
                                           systemImage: module.micMuted ? "mic.slash.fill" : "mic.fill") {
                            module.toggleMicMute()
                        }
                    }
                    CaptureGhostButton(title: "Discard", systemImage: "trash") { module.stopRecording(discard: true) }
                    Button { module.stopRecording() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                            .background(.red, in: Capsule())
                    }
                    .buttonStyle(.island)
                }
                .disabled(!module.machine.isRecording)
                if let hotKey = module.recordHotKey {
                    Text("or press \(hotKey.displayString)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String {
        var audio: [String] = []
        if module.systemAudio { audio.append("system audio") }
        if module.microphone { audio.append(module.micMuted ? "mic muted" : "mic") }
        let sound = audio.isEmpty ? "no audio" : audio.joined(separator: " + ")
        return "\(module.targetName) · \(sound)"
    }
}

private struct CountdownView: View {
    let remaining: Int
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(remaining > 0 ? "\(remaining)" : "")
                .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: remaining)
            CaptureGhostButton(title: "Cancel", systemImage: "xmark", action: cancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingDot: View {
    var pulsing: Bool
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !pulsing || reduceMotion)) { context in
            let phase = pulsing && !reduceMotion
                ? (sin(context.date.timeIntervalSinceReferenceDate * .pi) + 1) / 2 : 1
            Circle()
                .fill(.red)
                .frame(width: size, height: size)
                .opacity(0.45 + 0.55 * phase)
                .shadow(color: .red.opacity(0.6 * phase), radius: size / 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 9)
    }
}

// MARK: Saved

private struct SavedCard: View {
    let module: CaptureModule
    let item: CaptureItem
    @Environment(\.notchAccent) private var accent

    var body: some View {
        HStack(spacing: 16) {
            Thumbnail(url: item.url)
                .frame(width: 236, height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .overlay {
                    if item.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18))
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .onTapGesture { module.open(item) }
                .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                .help("Drag anywhere, or click to open")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(item.kind == .video ? "RECORDING SAVED" : "SCREENSHOT SAVED", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button { module.dismissSaved() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.island)
                    .help("Done")
                }
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Button { module.open(item) } label: {
                        Text("Open")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .foregroundStyle(.black)
                            .background(accent, in: Capsule())
                    }
                    .buttonStyle(.island)
                    CaptureGhostButton(title: "Show in Finder", systemImage: "folder") { module.reveal(item) }
                    CaptureGhostButton(title: "Copy", systemImage: "doc.on.doc") { module.copy(item) }
                    CaptureGhostButton(title: nil, systemImage: "trash") { module.delete(item) }
                        .help("Move to Trash")
                }
            }
            .frame(maxHeight: 148)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var details: String {
        let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let folder = item.url.deletingLastPathComponent().lastPathComponent
        return [sizeText, "in \(folder)"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: Permission

private struct PermissionCard: View {
    @Environment(\.notchAccent) private var accent

    var body: some View {
        let lost = CapturePermissions.wasScreenAccessLost
        HStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 40))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(lost ? "Turn Screen Recording back on" : "Allow Screen Recording")
                    .font(.system(size: 15, weight: .semibold))
                Text(lost
                     ? "macOS turned it off after the update. In System Settings, switch NotchPilot off and on again, then reopen NotchPilot."
                     : "NotchPilot needs Screen Recording permission for recordings and screenshots. Turn it on in System Settings, then reopen NotchPilot.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { CapturePermissions.requestScreenAccess() } label: {
                        Text("Open System Settings")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .foregroundStyle(.black)
                            .background(accent, in: Capsule())
                    }
                    .buttonStyle(.island)
                    CaptureGhostButton(title: "Reopen NotchPilot", systemImage: "arrow.clockwise") {
                        CapturePermissions.relaunch()
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Shared

struct CaptureGhostButton: View {
    let title: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Label(title, systemImage: systemImage)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(.white.opacity(0.85))
            .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.island)
    }
}

/// A Quick Look thumbnail of an image or movie file.
private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url) }
    }
}

@MainActor
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: NSImage] = [:]

    func image(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 480, height: 300),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        if cache.count > 40 { cache.removeAll() }
        cache[url] = image
        return image
    }
}

// MARK: Settings

struct CaptureSettingsView: View {
    @Bindable var module: CaptureModule

    var body: some View {
        Form {
            Section("Recording") {
                if !module.canRecord {
                    Text("Screen recording needs macOS 15 or later. Screenshots work on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Toggle("Record system audio", isOn: $module.systemAudio)
                Toggle("Record microphone", isOn: $module.microphone)
                Picker("Microphone", selection: $module.microphoneID) {
                    Text("Default").tag(String?.none)
                    ForEach(CapturePermissions.microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                .disabled(!module.microphone)
                Picker("Frame rate", selection: $module.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Show the pointer", isOn: $module.showsCursor)
                Toggle("Highlight clicks", isOn: $module.showsClicks)
                Toggle("Count down 3 seconds before recording", isOn: $module.countdown)
                Toggle("Smaller files (HEVC)", isOn: $module.hevc)
                Text("Turn off HEVC for H.264, which plays everywhere, including older Windows PCs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Screenshots") {
                Toggle("Copy screenshots to the clipboard instead of saving", isOn: $module.copyScreenshots)
            }
            Section("Save to") {
                FolderRow(title: "Recordings", url: module.recordingsFolder) { module.chooseFolder(screenshots: false) }
                FolderRow(title: "Screenshots", url: module.screenshotsFolder) { module.chooseFolder(screenshots: true) }
            }
            Section("Shortcuts") {
                LabeledContent("Start / stop recording") { HotKeyRecorder(combo: $module.recordHotKey) }
                LabeledContent("Screenshot of an area") { HotKeyRecorder(combo: $module.screenshotHotKey) }
            }
            Section("Permissions") {
                Text("Recordings and screenshots need Screen Recording permission; the mic needs Microphone permission. NotchPilot itself never appears in your captures, and nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Screen Recording settings…") { CapturePermissions.openScreenSettings() }
                    Button("Microphone settings…") { CapturePermissions.openMicrophoneSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderRow: View {
    let title: String
    let url: URL
    let change: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…", action: change)
            }
        }
    }
}
