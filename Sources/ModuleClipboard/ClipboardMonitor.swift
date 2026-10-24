import AppKit

/// Polls the general pasteboard (macOS has no change notification) and
/// records new content into the store.
@MainActor
final class ClipboardMonitor {
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    var excludedBundleIDs: Set<String> = []

    /// Images larger than this aren't stored.
    private static let maxImageBytes = 10 * 1024 * 1024

    init(store: ClipboardStore) {
        self.store = store
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Puts an item back on the pasteboard, marked so we don't re-record it.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let url = store.imageURL(for: item), let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        case .files:
            pasteboard.writeObjects((item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        }
        pasteboard.setString("", forType: NSPasteboard.PasteboardType(ClipboardFilter.internalType))
        lastChangeCount = pasteboard.changeCount
        // Still bump it to the top of the history.
        var bumped = item
        bumped.date = Date()
        store.add(bumped)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let types = pasteboard.types?.map(\.rawValue) ?? []
        let app = NSWorkspace.shared.frontmostApplication
        guard ClipboardFilter.shouldRecord(types: types, sourceBundleID: app?.bundleIdentifier,
                                           excludedBundleIDs: excludedBundleIDs) else { return }

        if let item = read(pasteboard, sourceAppName: app?.localizedName) {
            store.add(item)
        }
    }

    private func read(_ pasteboard: NSPasteboard, sourceAppName: String?) -> ClipboardItem? {
        let now = Date()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return ClipboardItem(id: UUID(), kind: .files, filePaths: urls.map(\.path), sourceAppName: sourceAppName, date: now)
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return ClipboardItem(id: UUID(), kind: .text, text: string, sourceAppName: sourceAppName, date: now)
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), data.count <= Self.maxImageBytes,
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            let id = UUID()
            let fileName = id.uuidString + ".png"
            do {
                try png.write(to: store.imagesDirectory.appendingPathComponent(fileName))
            } catch {
                return nil
            }
            return ClipboardItem(id: id, kind: .image, imageFile: fileName, sourceAppName: sourceAppName, date: now)
        }
        return nil
    }
}
