import Foundation
import NotchShell
import Observation

struct ShelfItem: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Bookmark so the item survives the file being moved or renamed.
    var bookmark: Data
    let addedAt: Date

    func resolveURL() -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
    }
}

/// Files parked on the shelf, persisted to `shelf.json`.
@MainActor
@Observable
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    @ObservationIgnored private let file: JSONFile<[ShelfItem]>

    init(file: JSONFile<[ShelfItem]> = JSONFile(url: AppPaths.supportDirectory.appendingPathComponent("shelf.json"))) {
        self.file = file
        // Drop items whose files no longer exist.
        items = (file.load() ?? []).filter { item in
            guard let url = item.resolveURL() else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.compactMap { $0.resolveURL()?.standardizedFileURL })
        for url in urls where !existing.contains(url.standardizedFileURL) {
            guard let bookmark = try? url.bookmarkData() else { continue }
            items.append(ShelfItem(id: UUID(), name: url.lastPathComponent, bookmark: bookmark, addedAt: Date()))
        }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    var urls: [URL] { items.compactMap { $0.resolveURL() } }

    private func save() {
        file.save(items)
    }
}
