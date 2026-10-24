import AppKit
import Carbon.HIToolbox
import NotchShell
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class ClipboardModule: NotchModule {
    public let id = "clipboard"
    public let title = "Clipboard"
    public let systemImage = "doc.on.clipboard"

    let store = ClipboardStore()
    @ObservationIgnored private(set) lazy var monitor = ClipboardMonitor(store: store)
    @ObservationIgnored private weak var context: NotchContext?

    var excludedBundleIDs: [String] {
        didSet {
            UserDefaults.standard.set(excludedBundleIDs, forKey: "clipboard.excluded")
            monitor.excludedBundleIDs = Set(excludedBundleIDs)
        }
    }

    var hotKey: HotKeyCombo? {
        didSet {
            HotKeyCombo.store(hotKey, key: "clipboard.hotKey", in: .standard)
            registerHotKey()
        }
    }

    static let defaultHotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey), keyLabel: "V")

    public init() {
        let defaults = UserDefaults.standard
        excludedBundleIDs = defaults.stringArray(forKey: "clipboard.excluded") ?? []
        hotKey = defaults.object(forKey: "clipboard.hotKey") == nil
            ? Self.defaultHotKey
            : HotKeyCombo.load(key: "clipboard.hotKey", from: defaults)
    }

    public func start(context: NotchContext) {
        self.context = context
        monitor.excludedBundleIDs = Set(excludedBundleIDs)
        monitor.start()
        registerHotKey()
    }

    public func stop() {
        monitor.stop()
        HotKeyCenter.shared.unregister("clipboard")
        context = nil
    }

    private func registerHotKey() {
        guard context != nil else { return }
        HotKeyCenter.shared.register("clipboard", combo: hotKey) { [weak self] in
            guard let self else { return }
            self.context?.open(moduleID: self.id)
        }
    }

    public func makeExpandedView() -> AnyView {
        AnyView(ClipboardView(module: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(ClipboardSettingsView(module: self))
    }
}

private struct ClipboardView: View {
    let module: ClipboardModule
    @State private var query = ""
    @State private var copiedID: UUID?

    var body: some View {
        let items = module.store.search(query)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Search clipboard", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

            if items.isEmpty {
                Text(query.isEmpty ? "Copied items will appear here" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            ClipboardRow(item: item, store: module.store, isCopied: copiedID == item.id) {
                                module.monitor.copy(item)
                                copiedID = item.id
                                Task {
                                    try? await Task.sleep(for: .seconds(1.2))
                                    if copiedID == item.id { copiedID = nil }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let isCopied: Bool
    let copy: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 22, height: 22)
            Text(item.previewText.isEmpty ? " " : item.previewText)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isCopied {
                Text("Copied").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
            } else if isHovering {
                Button { store.togglePin(item.id) } label: {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                }
                .help(item.isPinned ? "Unpin" : "Pin")
                Button { store.remove(item.id) } label: {
                    Image(systemName: "trash")
                }
                .help("Delete")
            } else {
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                }
                Text(item.date, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovering ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: copy)
        .help(item.sourceAppName.map { "Copied from \($0) — click to copy" } ?? "Click to copy")
    }

    @ViewBuilder private var thumbnail: some View {
        switch item.kind {
        case .image:
            if let url = store.imageURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
            }
        case .files:
            if let path = item.filePaths?.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: "doc")
            }
        case .text:
            Image(systemName: "text.alignleft").foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct ClipboardSettingsView: View {
    @Bindable var module: ClipboardModule
    @State private var selectedExcluded: String?

    var body: some View {
        Form {
            LabeledContent("Open clipboard shortcut") {
                HotKeyRecorder(combo: $module.hotKey)
            }
            Picker("Keep history", selection: Binding(get: { module.store.maxItems }, set: { module.store.maxItems = $0 })) {
                ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0) items").tag($0) }
            }
            Section {
                List(selection: $selectedExcluded) {
                    ForEach(module.excludedBundleIDs, id: \.self) { bundleID in
                        Text(Self.appName(for: bundleID)).tag(bundleID)
                    }
                }
                .frame(minHeight: 80)
                HStack {
                    Button("Add App…", action: addExcludedApp)
                    Button("Remove") {
                        module.excludedBundleIDs.removeAll { $0 == selectedExcluded }
                    }
                    .disabled(selectedExcluded == nil)
                }
            } header: {
                Text("Never record copies from these apps")
            } footer: {
                Text("Passwords from password managers (1Password, Bitwarden, Keychain…) are never recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Clear History (keeps pinned)", role: .destructive) { module.store.clearUnpinned() }
            }
        }
        .formStyle(.grouped)
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !module.excludedBundleIDs.contains(id) {
                module.excludedBundleIDs.append(id)
            }
        }
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}
