import Foundation
@testable import ModuleCapture
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func recordingFlowGoesThroughEachPhase() {
    var machine = CaptureMachine()
    let started = machine.beginCountdown(seconds: 3)
    #expect(started)
    #expect(machine.phase == .countingDown(remaining: 3))
    let startedAgain = machine.beginCountdown(seconds: 3)
    #expect(!startedAgain) // already busy
    let ticks = [machine.tick(), machine.tick(), machine.tick()]
    #expect(ticks == [false, false, true]) // 3 → 2 → 1 → go
    machine.didStartRecording(at: t0)
    #expect(machine.isRecording)
    #expect(machine.elapsed(at: t0.addingTimeInterval(42)) == 42)
    let finishing = [machine.beginFinishing(), machine.beginFinishing()]
    #expect(finishing == [true, false])
    #expect(machine.isBusy)
    let item = CaptureItem(url: URL(fileURLWithPath: "/tmp/a.mov"), date: t0)
    machine.didSave(item)
    #expect(machine.phase == .saved(item))
    #expect(!machine.isBusy)
    let restarted = machine.beginCountdown(seconds: 0)
    #expect(restarted) // a new recording can start from the saved card
}

@Test func countdownCanBeCancelled() {
    var machine = CaptureMachine()
    _ = machine.beginCountdown(seconds: 3)
    _ = machine.tick()
    machine.reset()
    #expect(machine.phase == .idle)
    let tickedAfterCancel = machine.tick(), finishedAfterCancel = machine.beginFinishing()
    #expect(!tickedAfterCancel && !finishedAfterCancel)
}

@Test func formatsElapsedTime() {
    #expect(CaptureFormat.elapsed(0) == "0:00")
    #expect(CaptureFormat.elapsed(42.9) == "0:42")
    #expect(CaptureFormat.elapsed(725) == "12:05")
    #expect(CaptureFormat.elapsed(3723) == "1:02:03")
    #expect(CaptureFormat.elapsed(-5) == "0:00")
}

@Test func namesFilesWithoutCollisions() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let dir = URL(fileURLWithPath: "/tmp/caps")
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 21, minute: 4, second: 12))!
    let first = CaptureFormat.fileURL(in: dir, date: date, ext: "mov", calendar: calendar) { _ in false }
    #expect(first.lastPathComponent == "NotchPilot 2026-10-30 at 21.04.12.mov")
    let taken: Set<String> = ["NotchPilot 2026-10-30 at 21.04.12.mov", "NotchPilot 2026-10-30 at 21.04.12 (2).mov"]
    let third = CaptureFormat.fileURL(in: dir, date: date, ext: "mov", calendar: calendar) { taken.contains($0.lastPathComponent) }
    #expect(third.lastPathComponent == "NotchPilot 2026-10-30 at 21.04.12 (3).mov")
}

@Test func areaSelectionIsClampedEvenAndNotTiny() {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    // Dragged up-left, past the screen edge.
    let rect = AreaGeometry.selection(from: CGPoint(x: 400.4, y: 300), to: CGPoint(x: -50, y: 100.6), in: bounds, scale: 2)
    #expect(rect == CGRect(x: 0, y: 101, width: 400, height: 199))
    // At 2x, 199 pt = 398 px: even. At 1x it must round down to an even width.
    let oneX = AreaGeometry.selection(from: .zero, to: CGPoint(x: 101, y: 77), in: bounds, scale: 1)
    #expect(oneX?.width == 100 && oneX?.height == 76)
    #expect(AreaGeometry.selection(from: .zero, to: CGPoint(x: 20, y: 300), in: bounds, scale: 2) == nil)
}

@Test func stopsBelowOneGigabyteFree() {
    #expect(DiskGuard.shouldStop(freeBytes: 500_000_000))
    #expect(!DiskGuard.shouldStop(freeBytes: 5_000_000_000))
    #expect(!DiskGuard.shouldStop(freeBytes: nil))
}

@Test func listsNewestCapturesFirstAcrossFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID())")
    let movies = root.appendingPathComponent("Movies"), pictures = root.appendingPathComponent("Pictures")
    for dir in [movies, pictures] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }

    func make(_ dir: URL, _ name: String, minutesAgo: Double) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
    }
    try make(movies, "old.mov", minutesAgo: 30)
    try make(movies, "new.mov", minutesAgo: 1)
    try make(movies, "notes.txt", minutesAgo: 0) // not a capture
    try make(pictures, "shot.png", minutesAgo: 5)

    let items = CaptureLibrary.recent(in: [movies, pictures, movies], limit: 2)
    #expect(items.map(\.url.lastPathComponent) == ["new.mov", "shot.png"])
    #expect(items.map(\.kind) == [.video, .image])
}
