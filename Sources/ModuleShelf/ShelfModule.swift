import AppKit
import NotchShell
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class ShelfModule: NotchModule {
    public let id = "shelf"
    public let title = "Shelf"
    public let systemImage = "tray.full"

    let store = ShelfStore()

    public init() {}

    public func start(context: NotchContext) {}
    public func stop() {}

    public func makeExpandedView() -> AnyView {
        AnyView(ShelfView(store: store))
    }
}

private struct ShelfView: View {
    let store: ShelfStore
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 26))
                    Text("Drop files here to keep them handy")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.items) { item in
                            ShelfTile(item: item, store: store)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                HStack {
                    Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button {
                        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: store.urls)
                    } label: {
                        Label("AirDrop All", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear") { store.clear() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.white.opacity(isTargeted ? 0.6 : 0.15))
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Self.loadURLs(from: providers) { store.add($0) }
            return true
        }
    }

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let url = data.flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) {
                    collected.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(collected.urls) }
        }
    }
}

/// Thread-safe accumulator for item-provider callbacks.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.withLock { storage.append(url) }
    }

    var urls: [URL] { lock.withLock { storage } }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let store: ShelfStore
    @State private var isHovering = false

    var body: some View {
        let url = item.resolveURL()
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                    .resizable()
                    .frame(width: 52, height: 52)
                if isHovering {
                    Button { store.remove(item.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -4)
                }
            }
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .padding(6)
        .background(isHovering ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .onDrag {
            guard let url else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) {
            if let url { NSWorkspace.shared.open(url) }
        }
        .contextMenu {
            if let url {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Quick Look") { Self.quickLook(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("AirDrop") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                Divider()
            }
            Button("Remove from Shelf") { store.remove(item.id) }
        }
        .help(url?.path ?? item.name)
    }

    static func quickLook(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
