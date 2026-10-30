import AppKit
import Carbon.HIToolbox
import NotchShell
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Screen recordings and screenshots, started from the notch.
@MainActor
@Observable
public final class CaptureModule: NotchModule {
    public let id = "capture"
    public let title = "Capture"
    public let systemImage = "record.circle"

    // MARK: Settings

    var mode: CaptureMode { didSet { save(mode.rawValue, "capture.mode") } }
    var systemAudio: Bool { didSet { save(systemAudio, "capture.systemAudio") } }
    var microphone: Bool { didSet { save(microphone, "capture.microphone") } }
    var microphoneID: String? { didSet { save(microphoneID ?? "", "capture.microphoneID") } }
    var fps: Int { didSet { save(fps, "capture.fps") } }
    var showsCursor: Bool { didSet { save(showsCursor, "capture.cursor") } }
    var showsClicks: Bool { didSet { save(showsClicks, "capture.clicks") } }
    var countdown: Bool { didSet { save(countdown, "capture.countdown") } }
    var hevc: Bool { didSet { save(hevc, "capture.hevc") } }
    var copyScreenshots: Bool { didSet { save(copyScreenshots, "capture.copyScreenshots") } }
    var recordingsFolder: URL { didSet { save(recordingsFolder.path, "capture.recordingsFolder"); refreshRecents() } }
    var screenshotsFolder: URL { didSet { save(screenshotsFolder.path, "capture.screenshotsFolder"); refreshRecents() } }
    var recordHotKey: HotKeyCombo? {
        didSet { HotKeyCombo.store(recordHotKey, key: "capture.recordHotKey", in: .standard); registerHotKeys() }
    }
    var screenshotHotKey: HotKeyCombo? {
        didSet { HotKeyCombo.store(screenshotHotKey, key: "capture.screenshotHotKey", in: .standard); registerHotKeys() }
    }

    static let defaultRecordHotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_R),
                                                 modifiers: UInt32(cmdKey | optionKey | controlKey), keyLabel: "R")
    static let defaultScreenshotHotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_S),
                                                     modifiers: UInt32(cmdKey | optionKey | controlKey), keyLabel: "S")

    // MARK: State

    private(set) var machine = CaptureMachine()
    private(set) var micMuted = false
    private(set) var recents: [CaptureItem] = []
    private(set) var errorMessage: String?
    /// What's being recorded, e.g. "Built-in Retina Display".
    private(set) var targetName = ""

    var canRecord: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    @ObservationIgnored private weak var context: NotchContext?
    @ObservationIgnored private var recorder: AnyObject?
    @ObservationIgnored private let windowPicker = WindowPicker()
    @ObservationIgnored private var discardWhenDone = false
    @ObservationIgnored private var diskTask: Task<Void, Never>?
    @ObservationIgnored private var savedTask: Task<Void, Never>?

    public init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "capture.mode": CaptureMode.screen.rawValue, "capture.systemAudio": true, "capture.microphone": false,
            "capture.fps": 30, "capture.cursor": true, "capture.clicks": false, "capture.countdown": true,
            "capture.hevc": true, "capture.copyScreenshots": false,
        ])
        mode = CaptureMode(rawValue: d.string(forKey: "capture.mode") ?? "") ?? .screen
        systemAudio = d.bool(forKey: "capture.systemAudio")
        microphone = d.bool(forKey: "capture.microphone")
        microphoneID = d.string(forKey: "capture.microphoneID").flatMap { $0.isEmpty ? nil : $0 }
        fps = d.integer(forKey: "capture.fps")
        showsCursor = d.bool(forKey: "capture.cursor")
        showsClicks = d.bool(forKey: "capture.clicks")
        countdown = d.bool(forKey: "capture.countdown")
        hevc = d.bool(forKey: "capture.hevc")
        copyScreenshots = d.bool(forKey: "capture.copyScreenshots")
        recordingsFolder = d.string(forKey: "capture.recordingsFolder").map { URL(fileURLWithPath: $0) }
            ?? CaptureLibrary.defaultRecordingsFolder
        screenshotsFolder = d.string(forKey: "capture.screenshotsFolder").map { URL(fileURLWithPath: $0) }
            ?? CaptureLibrary.defaultScreenshotsFolder
        recordHotKey = d.object(forKey: "capture.recordHotKey") == nil
            ? Self.defaultRecordHotKey : HotKeyCombo.load(key: "capture.recordHotKey", from: d)
        screenshotHotKey = d.object(forKey: "capture.screenshotHotKey") == nil
            ? Self.defaultScreenshotHotKey : HotKeyCombo.load(key: "capture.screenshotHotKey", from: d)
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: Lifecycle

    public func start(context: NotchContext) {
        self.context = context
        registerHotKeys()
        refreshRecents()
    }

    public func stop() {
        HotKeyCenter.shared.unregister("capture.record")
        HotKeyCenter.shared.unregister("capture.screenshot")
        if machine.isRecording { stopRecording() }
        context = nil
    }

    private func registerHotKeys() {
        guard context != nil else { return }
        HotKeyCenter.shared.register("capture.record", combo: recordHotKey) { [weak self] in self?.toggleRecording() }
        HotKeyCenter.shared.register("capture.screenshot", combo: screenshotHotKey) { [weak self] in
            self?.takeScreenshot(.area)
        }
    }

    // MARK: Recording

    func toggleRecording() {
        switch machine.phase {
        case .countingDown: cancelCountdown()
        case .recording: stopRecording()
        case .finishing: break
        case .idle, .saved: Task { await startRecording() }
        }
    }

    func startRecording() async {
        guard #available(macOS 15.0, *) else { return fail(CaptureError.needsMacOS15) }
        guard !machine.isBusy else { return }
        errorMessage = nil
        savedTask?.cancel()
        if case .saved = machine.phase { machine.reset() }
        if mode != .window, !CapturePermissions.hasScreenAccess {
            CapturePermissions.requestScreenAccess()
            context?.open(moduleID: id, takeFocus: false)
            return
        }
        if microphone, !(await CapturePermissions.requestMicrophone()) {
            return fail(CaptureError.microphoneDenied)
        }

        context?.close()
        let filter: SCContentFilter
        var sourceRect: CGRect?
        do {
            switch mode {
            case .screen:
                let (displayFilter, screen) = try await CaptureContent.displayFilter(for: NSScreen.underPointer)
                filter = displayFilter
                targetName = screen.localizedName
            case .area:
                try? await Task.sleep(for: .milliseconds(250)) // let the island close first
                guard let (screen, rect) = await AreaSelector().select() else { return }
                filter = try await CaptureContent.displayFilter(for: screen).0
                sourceRect = rect
                targetName = "Area on \(screen.localizedName)"
            case .window:
                guard let picked = await windowPicker.pick() else { return }
                filter = picked
                targetName = "Window"
            }
        } catch {
            return fail(error)
        }

        guard machine.beginCountdown(seconds: countdown ? 3 : 0) else { return }
        if countdown {
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard case .countingDown = machine.phase else { return windowPicker.deactivate() } // cancelled
                if machine.tick() { break }
            }
        }

        let folder = recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = CaptureFormat.fileURL(in: folder, date: Date(), ext: "mov") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let options = RecordingOptions(systemAudio: systemAudio, microphone: microphone, microphoneID: microphoneID,
                                       fps: fps, showsCursor: showsCursor, showsClicks: showsClicks, hevc: hevc)
        let recorder = ScreenRecorder()
        recorder.onFinish = { [weak self] in self?.recordingFinished($0) }
        do {
            try await recorder.start(filter: filter, sourceRect: sourceRect, options: options, to: url)
        } catch {
            machine.reset()
            windowPicker.deactivate()
            return fail(error)
        }
        self.recorder = recorder
        discardWhenDone = false
        micMuted = false
        machine.didStartRecording(at: Date())
        CaptureStatus.shared.isRecording = true
        context?.select(moduleID: id)
        watchDiskSpace()
    }

    func cancelCountdown() {
        guard case .countingDown = machine.phase else { return }
        machine.reset()
    }

    func stopRecording(discard: Bool = false) {
        guard machine.beginFinishing() else { return }
        discardWhenDone = discard
        diskTask?.cancel()
        if #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder {
            Task { await recorder.stop() }
        }
    }

    func toggleMicMute() {
        guard #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder else { return }
        micMuted.toggle()
        let muted = micMuted
        Task { await recorder.setMicrophoneMuted(muted) }
    }

    private func recordingFinished(_ result: Result<URL, Error>) {
        recorder = nil
        diskTask?.cancel()
        windowPicker.deactivate()
        CaptureStatus.shared.isRecording = false
        switch result {
        case let .success(url):
            if discardWhenDone {
                NSWorkspace.shared.recycle([url])
                machine.reset()
                refreshRecents()
            } else {
                showSaved(CaptureItem(url: url, date: Date()))
            }
        case let .failure(error):
            machine.reset()
            fail(error)
        }
    }

    private func watchDiskSpace() {
        diskTask?.cancel()
        let folder = recordingsFolder
        diskTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                if DiskGuard.shouldStop(freeBytes: DiskGuard.freeBytes(at: folder)) {
                    self?.errorMessage = "Stopped recording: your disk is almost full."
                    self?.toast("Disk almost full", systemImage: "externaldrive.badge.exclamationmark", color: .orange)
                    self?.stopRecording()
                    return
                }
            }
        }
    }

    // MARK: Screenshots

    func takeScreenshot(_ kind: CaptureMode) {
        Task {
            errorMessage = nil
            guard CapturePermissions.hasScreenAccess else {
                CapturePermissions.requestScreenAccess()
                return
            }
            context?.close()
            try? await Task.sleep(for: .milliseconds(300)) // let the island close
            var url: URL?
            if !copyScreenshots {
                try? FileManager.default.createDirectory(at: screenshotsFolder, withIntermediateDirectories: true)
                url = CaptureFormat.fileURL(in: screenshotsFolder, date: Date(), ext: "png") {
                    FileManager.default.fileExists(atPath: $0.path)
                }
            }
            switch kind {
            case .screen:
                do {
                    try await Screenshotter.captureScreen(to: url)
                } catch {
                    return fail(error)
                }
            case .window, .area:
                guard await Screenshotter.captureInteractive(window: kind == .window, to: url) else { return }
            }
            guard let url else {
                return toast("Copied", systemImage: "doc.on.clipboard", color: .green)
            }
            if machine.isBusy {
                // Don't interrupt a recording with the preview.
                refreshRecents()
                toast("Saved", systemImage: "camera.fill", color: .green)
            } else {
                showSaved(CaptureItem(url: url, date: Date()))
            }
        }
    }

    // MARK: Saved items

    private func showSaved(_ item: CaptureItem) {
        machine.didSave(item)
        refreshRecents()
        context?.open(moduleID: id, takeFocus: false)
        savedTask?.cancel()
        savedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            // Keep it while the pointer is over the island.
            while !Task.isCancelled, self?.context?.isPointerInside == true {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self, case .saved = self.machine.phase else { return }
            self.machine.reset()
            self.context?.close()
        }
    }

    func dismissSaved() {
        savedTask?.cancel()
        if case .saved = machine.phase { machine.reset() }
    }

    func refreshRecents() {
        recents = CaptureLibrary.recent(in: [recordingsFolder, screenshotsFolder], limit: 6)
    }

    func open(_ item: CaptureItem) {
        NSWorkspace.shared.open(item.url)
        dismissSaved()
        context?.close()
    }

    func reveal(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        dismissSaved()
        context?.close()
    }

    func copy(_ item: CaptureItem) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
        if item.kind == .image, let data = try? Data(contentsOf: item.url) {
            pasteboardItem.setData(data, forType: .png)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pasteboardItem])
        toast("Copied", systemImage: "doc.on.clipboard", color: .green)
    }

    func delete(_ item: CaptureItem) {
        NSWorkspace.shared.recycle([item.url]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshRecents() }
        }
        if case let .saved(saved) = machine.phase, saved == item { dismissSaved() }
        recents.removeAll { $0 == item }
    }

    func chooseFolder(screenshots: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = screenshots ? screenshotsFolder : recordingsFolder
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if screenshots { screenshotsFolder = url } else { recordingsFolder = url }
    }

    // MARK: Feedback

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        toast("Capture failed", systemImage: "exclamationmark.triangle.fill", color: .orange)
    }

    private func toast(_ text: String, systemImage: String, color: Color) {
        context?.showTransient(CompactActivity(id: "capture-toast-\(text)", priority: 95, sideWidth: 96) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        } trailing: {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
        }, for: .seconds(2))
    }

    // MARK: NotchModule

    public var compactActivity: CompactActivity? {
        switch machine.phase {
        case let .countingDown(remaining):
            return CompactActivity(id: "capture-countdown", priority: 80, sideWidth: 40) {
                RecordingDot(pulsing: false)
            } trailing: {
                Text(remaining > 0 ? "\(remaining)" : "")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
            }
        case let .recording(start):
            return CompactActivity(id: "capture-recording", priority: 80, sideWidth: 58) {
                RecordingDot(pulsing: true)
            } trailing: {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(CaptureFormat.elapsed(context.date.timeIntervalSince(start)))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
            }
        case .finishing:
            return CompactActivity(id: "capture-finishing", priority: 80, sideWidth: 58) {
                RecordingDot(pulsing: false)
            } trailing: {
                ProgressView()
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        case .idle, .saved:
            return nil
        }
    }

    public func makeExpandedView() -> AnyView {
        AnyView(CaptureView(module: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(CaptureSettingsView(module: self))
    }
}
