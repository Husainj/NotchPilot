import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum Screenshotter {
    /// The whole display under the pointer, without NotchPilot. Writes a PNG
    /// to `url`, or copies it to the clipboard when `url` is nil.
    @MainActor
    static func captureScreen(to url: URL?) async throws {
        let (filter, _) = try await CaptureContent.displayFilter(for: NSScreen.underPointer)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if let url {
            try writePNG(image, to: url)
        } else {
            let rep = NSBitmapImageRep(cgImage: image)
            NSPasteboard.general.clearContents()
            if let data = rep.representation(using: .png, properties: [:]) {
                NSPasteboard.general.setData(data, forType: .png)
            }
        }
    }

    /// Lets the user pick a window or drag an area with macOS's own
    /// screenshot tool. Returns false if they cancelled.
    static func captureInteractive(window: Bool, to url: URL?) async -> Bool {
        var args = ["-i", window ? "-w" : "-s"]
        args += url == nil ? ["-c"] : [url!.path]
        let changeCount = await MainActor.run { NSPasteboard.general.changeCount }
        let status = await run("/usr/sbin/screencapture", args)
        guard status == 0 else { return false }
        if let url { return FileManager.default.fileExists(atPath: url.path) }
        return await MainActor.run { NSPasteboard.general.changeCount != changeCount }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func run(_ path: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}
