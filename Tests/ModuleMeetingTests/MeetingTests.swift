import Foundation
import NotchShell
import Testing
@testable import ModuleMeeting

@Test func findsCallLinksInEvents() {
    let zoom = MeetingLink.find(url: nil, location: "Zoom: https://us02web.zoom.us/j/8123456789?pwd=abc123",
                                notes: nil)
    #expect(zoom?.absoluteString == "https://us02web.zoom.us/j/8123456789?pwd=abc123")
    let meet = MeetingLink.find(url: URL(string: "https://example.com/agenda"), location: nil,
                                notes: "Agenda: https://docs.google.com/x\nJoin with Google Meet: https://meet.google.com/abc-defg-hij")
    #expect(meet?.host == "meet.google.com")
    let teams = MeetingLink.find(url: nil, location: nil,
                                 notes: "Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x")
    #expect(teams.flatMap(MeetingLink.service) == .teams)
    #expect(MeetingLink.find(url: nil, location: "Room 4B", notes: "https://zoom.us/pricing") == nil)
    #expect(MeetingLink.service(for: URL(string: "https://meet.google.com/")!) == nil)
}

@Test func opensZoomAndTeamsInTheirApps() {
    let zoom = URL(string: "https://us02web.zoom.us/j/8123456789?pwd=abc123")!
    let app = MeetingLink.appURL(for: zoom, isInstalled: { _ in true })
    #expect(app.absoluteString == "zoommtg://us02web.zoom.us/join?action=join&confno=8123456789&pwd=abc123")
    #expect(MeetingLink.appURL(for: zoom, isInstalled: { _ in false }) == zoom)

    let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0")!
    #expect(MeetingLink.appURL(for: teams, isInstalled: { _ in true }).absoluteString == "msteams:/l/meetup-join/19%3ameeting_abc/0")
}

@Test func attributesMicUseToRealApps() {
    let apps: [MicAttribution.App] = [("com.google.Chrome", "Google Chrome", 100), ("us.zoom.xos", "zoom.us", 200),
                                      ("com.apple.Safari", "Safari", 300)]
    #expect(MicAttribution.app(forBundleID: "us.zoom.xos", pid: 200, regularApps: apps)?.name == "zoom.us")
    #expect(MicAttribution.app(forBundleID: "com.google.Chrome.helper", pid: 999, regularApps: apps)?.name == "Google Chrome")
    #expect(MicAttribution.app(forBundleID: "com.apple.WebKit.GPU", pid: 998, regularApps: apps)?.name == "Safari")
    #expect(MicAttribution.app(forBundleID: "com.apple.corespeechd", pid: 997, regularApps: apps) == nil)
    #expect(MicAttribution.app(forBundleID: "", pid: 996, regularApps: apps) == nil)
    #expect(MicAttribution.app(forBundleID: "com.hnc.Discord.helper", pid: 995, regularApps: apps)?.bundleID == "com.hnc.Discord.helper")
}

@Test func callsAreDebounced() {
    var tracker = CallTracker()
    let t0 = Date(timeIntervalSince1970: 1000)
    // A 2-second dictation isn't a call.
    #expect(tracker.update(active: true, now: t0) == nil)
    #expect(tracker.update(active: false, now: t0.addingTimeInterval(2)) == nil)
    #expect(!tracker.isInCall)

    #expect(tracker.update(active: true, now: t0.addingTimeInterval(10)) == nil)
    #expect(tracker.pendingDeadline == t0.addingTimeInterval(14))
    #expect(tracker.update(active: true, now: t0.addingTimeInterval(14)) == .started)
    #expect(tracker.callStart == t0.addingTimeInterval(10))

    // A brief device switch doesn't end the call.
    #expect(tracker.update(active: false, now: t0.addingTimeInterval(100)) == nil)
    #expect(tracker.update(active: true, now: t0.addingTimeInterval(103)) == nil)
    #expect(tracker.isInCall)

    #expect(tracker.update(active: false, now: t0.addingTimeInterval(200)) == nil)
    #expect(tracker.update(active: false, now: t0.addingTimeInterval(206)) == .ended(duration: 190))
    #expect(!tracker.isInCall)
}

// CI machines usually have no microphone, so this only runs where one exists.
@MainActor @Test(.enabled(if: CA.defaultInputDevice() != 0)) func readsTheRealInputDevice() {
    // Sanity check against this Mac's hardware: the default mic has a name.
    let device = CA.defaultInputDevice()
    #expect(device != 0)
    #expect(CA.deviceName(device)?.isEmpty == false)
    _ = CameraMonitor.anyCameraRunning()
}
