import AppKit
import AVFoundation
import CoreGraphics

@MainActor
enum CapturePermissions {
    private static let grantedKey = "capture.screenWasGranted"

    /// Screen Recording access. macOS only rechecks this when the app relaunches.
    static var hasScreenAccess: Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if granted { UserDefaults.standard.set(true, forKey: grantedKey) }
        return granted
    }

    /// Granted before but not now: an update changed the app's signature, so
    /// macOS forgot the permission.
    static var wasScreenAccessLost: Bool {
        !hasScreenAccess && UserDefaults.standard.bool(forKey: grantedKey)
    }

    /// Shows the system prompt the first time, then opens System Settings.
    static func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess() {
            openScreenSettings()
        }
    }

    static func openScreenSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks for the microphone if needed. Returns whether it can be used.
    static func requestMicrophone() async -> Bool {
        switch micStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
    }

    /// Quits and reopens NotchPilot so a newly granted permission takes effect.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
