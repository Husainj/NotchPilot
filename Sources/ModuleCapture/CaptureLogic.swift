import CoreGraphics
import Foundation

/// What to record.
enum CaptureMode: String, CaseIterable, Identifiable {
    case screen, window, area
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: "Screen"
        case .window: "Window"
        case .area: "Area"
        }
    }

    var systemImage: String {
        switch self {
        case .screen: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

/// A saved recording or screenshot.
struct CaptureItem: Identifiable, Equatable, Hashable {
    enum Kind { case video, image }

    let url: URL
    let date: Date
    var id: URL { url }

    var kind: Kind { CaptureLibrary.imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .video }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The recording flow: idle → countdown → recording → finishing → saved.
struct CaptureMachine: Equatable {
    enum Phase: Equatable {
        case idle
        case countingDown(remaining: Int)
        case recording(start: Date)
        case finishing
        case saved(CaptureItem)
    }

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .countingDown, .recording, .finishing: true
        case .idle, .saved: false
        }
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Starts a countdown. Returns false if something is already in progress.
    mutating func beginCountdown(seconds: Int) -> Bool {
        guard !isBusy else { return false }
        phase = .countingDown(remaining: max(seconds, 0))
        return true
    }

    /// One second passed. Returns true when the countdown is over and recording should start.
    mutating func tick() -> Bool {
        guard case let .countingDown(remaining) = phase else { return false }
        if remaining <= 1 {
            phase = .countingDown(remaining: 0)
            return true
        }
        phase = .countingDown(remaining: remaining - 1)
        return false
    }

    mutating func didStartRecording(at date: Date) {
        phase = .recording(start: date)
    }

    /// Stop was requested. Returns false if nothing was recording.
    mutating func beginFinishing() -> Bool {
        guard isRecording else { return false }
        phase = .finishing
        return true
    }

    mutating func didSave(_ item: CaptureItem) {
        phase = .saved(item)
    }

    /// Cancel a countdown, a failed start, a discard, or close the saved card.
    mutating func reset() {
        phase = .idle
    }

    func elapsed(at now: Date) -> TimeInterval {
        if case let .recording(start) = phase { return max(now.timeIntervalSince(start), 0) }
        return 0
    }
}

enum CaptureFormat {
    /// 0:42, 12:05, 1:02:03.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "NotchPilot 2026-10-30 at 21.04.12.mov", with " (2)", " (3)"… if taken.
    static func fileURL(in directory: URL, date: Date, ext: String,
                        calendar: Calendar = .current, exists: (URL) -> Bool) -> URL {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let base = String(format: "NotchPilot %04d-%02d-%02d at %02d.%02d.%02d",
                          c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while exists(url) {
            url = directory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

enum AreaGeometry {
    /// Smallest area worth recording, in points.
    static let minimumSize: CGFloat = 32

    /// The rectangle dragged from `start` to `end`, clamped to `bounds`, with
    /// even pixel dimensions (video encoders need them). Nil when too small.
    static func selection(from start: CGPoint, to end: CGPoint, in bounds: CGRect, scale: CGFloat) -> CGRect? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(bounds)
        guard !rect.isNull, rect.width >= minimumSize, rect.height >= minimumSize else { return nil }
        let step = 2 / max(scale, 1)
        let width = (rect.width / step).rounded(.down) * step
        let height = (rect.height / step).rounded(.down) * step
        return CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: width, height: height)
    }
}

enum DiskGuard {
    /// Stop recording below this much free space.
    static let minimumFreeBytes: Int64 = 1_000_000_000

    static func shouldStop(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < minimumFreeBytes
    }

    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

enum CaptureLibrary {
    static let videoExtensions: Set<String> = ["mov", "mp4"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    static let defaultRecordingsFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchPilot", isDirectory: true)
    static let defaultScreenshotsFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchPilot", isDirectory: true)

    /// Newest recordings and screenshots across `folders`.
    static func recent(in folders: [URL], limit: Int) -> [CaptureItem] {
        let fm = FileManager.default
        var items: [CaptureItem] = []
        for folder in Set(folders) {
            let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard videoExtensions.contains(ext) || imageExtensions.contains(ext) else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                items.append(CaptureItem(url: url, date: date))
            }
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }
}
