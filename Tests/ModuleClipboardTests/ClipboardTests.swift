import Foundation
import Testing
@testable import ModuleClipboard

@Test func concealedAndTransientCopiesAreSkipped() {
    for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
        #expect(!ClipboardFilter.shouldRecord(types: ["public.utf8-plain-text", type], sourceBundleID: nil, excludedBundleIDs: []))
    }
}

@Test func excludedAppsAreSkipped() {
    #expect(!ClipboardFilter.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: "com.bank.app", excludedBundleIDs: ["com.bank.app"]))
    #expect(ClipboardFilter.shouldRecord(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari", excludedBundleIDs: ["com.bank.app"]))
}

@MainActor
private func makeStore(maxItems: Int = 200) -> ClipboardStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "notch-tests-\(UUID().uuidString)")!
    let store = ClipboardStore(directory: dir, defaults: defaults)
    store.maxItems = maxItems
    return store
}

private func text(_ s: String) -> ClipboardItem {
    ClipboardItem(id: UUID(), kind: .text, text: s, date: Date())
}

@MainActor @Test func duplicateTextMovesToTop() {
    let store = makeStore()
    store.add(text("a"))
    store.add(text("b"))
    store.add(text("a"))
    #expect(store.items.map(\.text) == ["a", "b"])
}

@MainActor @Test func oldestUnpinnedItemsAreEvicted() {
    let store = makeStore(maxItems: 2)
    store.add(text("1"))
    store.togglePin(store.items[0].id)
    store.add(text("2"))
    store.add(text("3"))
    store.add(text("4"))
    // Pinned "1" survives; only the 2 newest unpinned are kept.
    #expect(Set(store.items.compactMap(\.text)) == ["1", "3", "4"])
}

@MainActor @Test func searchPutsPinnedFirst() {
    let store = makeStore()
    store.add(text("apple pie"))
    store.add(text("banana"))
    store.add(text("apple juice"))
    store.togglePin(store.items.first { $0.text == "apple pie" }!.id)
    #expect(store.search("apple").map(\.text) == ["apple pie", "apple juice"])
}

@MainActor @Test func historyPersistsAcrossLaunches() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "notch-tests-\(UUID().uuidString)")!
    ClipboardStore(directory: dir, defaults: defaults).add(text("saved"))
    #expect(ClipboardStore(directory: dir, defaults: defaults).items.first?.text == "saved")
}

@MainActor @Test func clearKeepsPinned() {
    let store = makeStore()
    store.add(text("keep"))
    store.togglePin(store.items[0].id)
    store.add(text("drop"))
    store.clearUnpinned()
    #expect(store.items.map(\.text) == ["keep"])
}
