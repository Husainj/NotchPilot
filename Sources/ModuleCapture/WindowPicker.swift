import AppKit
@preconcurrency import ScreenCaptureKit

/// Apple's window/app picker. It shows its own previews and doesn't need
/// the Screen Recording permission.
@MainActor
final class WindowPicker: NSObject {
    private var continuation: CheckedContinuation<MainActorBox<SCContentFilter?>, Never>?

    func pick() async -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleApplication]
        if let bundleID = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [bundleID] }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        NSApp.activate()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }.value
    }

    /// Call when the recording that used the picked content has ended.
    func deactivate() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func finish(_ filter: SCContentFilter?) {
        if filter == nil { deactivate() }
        continuation?.resume(returning: MainActorBox(value: filter))
        continuation = nil
    }
}

extension WindowPicker: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        Task { @MainActor in self.finish(filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
