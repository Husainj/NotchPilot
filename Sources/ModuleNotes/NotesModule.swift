import NotchShell
import SwiftUI

struct Note: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var updatedAt: Date

    /// First non-empty line.
    var title: String {
        text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "New note"
    }
}

/// Scratchpad + notes, persisted to `notes.json`.
@MainActor
@Observable
final class NotesStore {
    static let scratchpadID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private(set) var notes: [Note]
    @ObservationIgnored private let file: JSONFile<[Note]>
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(file: JSONFile<[Note]> = JSONFile(url: AppPaths.supportDirectory.appendingPathComponent("notes.json"))) {
        self.file = file
        var loaded = file.load() ?? []
        if !loaded.contains(where: { $0.id == Self.scratchpadID }) {
            loaded.insert(Note(id: Self.scratchpadID, text: "", updatedAt: Date()), at: 0)
        }
        notes = loaded
    }

    var scratchpad: Note { notes.first { $0.id == Self.scratchpadID }! }

    /// Regular notes, most recently edited first.
    var others: [Note] {
        notes.filter { $0.id != Self.scratchpadID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func text(of id: UUID) -> String {
        notes.first { $0.id == id }?.text ?? ""
    }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updatedAt = Date()
        scheduleSave()
    }

    @discardableResult
    func create() -> UUID {
        let note = Note(id: UUID(), text: "", updatedAt: Date())
        notes.append(note)
        scheduleSave()
        return note.id
    }

    func delete(_ id: UUID) {
        guard id != Self.scratchpadID else { return }
        notes.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Coalesces rapid typing into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.file.save(self.notes)
        }
    }

    func flush() {
        saveTask?.cancel()
        file.save(notes)
    }
}

@MainActor
@Observable
public final class NotesModule: NotchModule {
    public let id = "notes"
    public let title = "Notes"
    public let systemImage = "note.text"

    let store = NotesStore()
    var selectedID: UUID = NotesStore.scratchpadID

    public init() {}

    public func start(context: NotchContext) {}
    public func stop() { store.flush() }

    public func makeExpandedView() -> AnyView {
        AnyView(NotesView(module: self))
    }
}

private struct NotesView: View {
    @Bindable var module: NotesModule
    @Environment(\.notchAccent) private var accent

    var body: some View {
        let store = module.store
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                row(id: NotesStore.scratchpadID, title: "Scratchpad", symbol: "pencil.line")
                Divider().overlay(.white.opacity(0.1)).padding(.vertical, 3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.others) { note in
                            row(id: note.id, title: note.title, symbol: "doc.text")
                                .contextMenu {
                                    Button("Delete", role: .destructive) { delete(note.id) }
                                }
                        }
                    }
                }
                Button {
                    module.selectedID = store.create()
                } label: {
                    Label("New Note", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.island)
                .padding(.top, 4)
            }
            .frame(width: 150)

            ZStack(alignment: .topTrailing) {
                TextEditor(text: Binding(
                    get: { store.text(of: module.selectedID) },
                    set: { store.update(module.selectedID, text: $0) }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if store.text(of: module.selectedID).isEmpty {
                    Text(module.selectedID == NotesStore.scratchpadID ? "Jot something down…" : "Start typing…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                }
                if module.selectedID != NotesStore.scratchpadID {
                    Button { delete(module.selectedID) } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.island)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(8)
                    .help("Delete note")
                }
            }
        }
    }

    private func row(id: UUID, title: String, symbol: String) -> some View {
        let isSelected = module.selectedID == id
        return Button { module.selectedID = id } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.island)
    }

    private func delete(_ id: UUID) {
        module.store.delete(id)
        if module.selectedID == id { module.selectedID = NotesStore.scratchpadID }
    }
}
