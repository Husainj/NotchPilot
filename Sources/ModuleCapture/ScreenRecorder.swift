import AVFoundation
@preconcurrency import ScreenCaptureKit

struct RecordingOptions {
    var systemAudio = true
    var microphone = false
    var microphoneID: String?
    var fps = 30
    var showsCursor = true
    var showsClicks = false
    var hevc = true
}

/// Records a ScreenCaptureKit filter straight to a movie file, with system
/// audio and the microphone in the same synced file.
@available(macOS 15.0, *)
@MainActor
final class ScreenRecorder: NSObject {
    /// Called once with the finished file, or an error if nothing usable was written.
    var onFinish: ((Result<URL, Error>) -> Void)?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var config: SCStreamConfiguration?
    private var url: URL?
    private var started = false
    private var finished = false

    func start(filter: SCContentFilter, sourceRect: CGRect?, options: RecordingOptions, to url: URL) async throws {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = sourceRect?.size ?? filter.contentRect.size
        config.width = Self.even(size.width * scale)
        config.height = Self.even(size.height * scale)
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 6
        config.showsCursor = options.showsCursor
        config.showMouseClicks = options.showsClicks
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = options.microphone
        config.microphoneCaptureDeviceID = options.microphone ? options.microphoneID : nil

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = options.hevc ? .hevc : .h264

        let output = SCRecordingOutput(configuration: recording, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream
        self.output = output
        self.config = config
        self.url = url
        try await stream.startCapture()
        started = true
    }

    /// Stops and finalizes the file; `onFinish` fires when it's written.
    func stop() async {
        guard let stream, started else { return }
        started = false
        do {
            // Removing the output finalizes the file and fires the delegate;
            // stopCapture alone doesn't always.
            if let output { try stream.removeRecordingOutput(output) }
            try await stream.stopCapture()
        } catch {
            // Already stopped (e.g. from the menu bar); the delegate reports the result.
        }
        // The delegate normally reports within a moment; don't hang if it doesn't.
        for _ in 0..<40 where !finished {
            try? await Task.sleep(for: .milliseconds(100))
        }
        finishAfterError(CocoaError(.fileWriteUnknown))
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        guard let stream, let config else { return }
        config.captureMicrophone = !muted
        try? await stream.updateConfiguration(config)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        stream = nil
        output = nil
        onFinish?(result)
        onFinish = nil
    }

    /// The file is usable if it exists and isn't empty, even after an error.
    private func finishAfterError(_ error: Error) {
        if let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            finish(.success(url))
        } else {
            finish(.failure(error))
        }
    }

    private static func even(_ value: CGFloat) -> Int {
        max(Int(value.rounded()) & ~1, 2)
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The recording output finalizes the file and reports below; this
        // covers the case where it never started writing.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.finishAfterError(error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let url = self.url else { return }
            self.finish(.success(url))
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.finishAfterError(error) }
    }
}

enum CaptureContent {
    /// Our own process, so the island never shows up in captures.
    @MainActor
    static func ownApplication(in content: SCShareableContent) -> [SCRunningApplication] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.applications.filter { $0.processID == pid }
    }

    /// The display under the pointer (or the main one) minus NotchPilot.
    @MainActor
    static func displayFilter(for screen: NSScreen?) async throws -> (SCContentFilter, NSScreen) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let id = screen.displayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication(in: content), exceptingWindows: [])
        return (filter, screen)
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case microphoneDenied
    case needsMacOS15

    var errorDescription: String? {
        switch self {
        case .noDisplay: "Couldn't find a display to record."
        case .microphoneDenied: "Microphone access is off. Turn it on in System Settings, or record without the mic."
        case .needsMacOS15: "Screen recording needs macOS 15 or later."
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The screen the pointer is on.
    static var underPointer: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
