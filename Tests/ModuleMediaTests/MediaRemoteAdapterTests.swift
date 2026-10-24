import Foundation
import Testing
@testable import ModuleMedia

private func payload(_ json: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

/// Real adapter output captured from `stream --micros`.
@Test func parsesStreamPayload() throws {
    let info = try #require(MediaRemoteAdapter.parse(payload("""
    {"artist":"Test Artist","timestampEpochMicros":1791879369902881,"title":"Test Song",
     "elapsedTimeMicros":42000000,"durationMicros":200000000,"processIdentifier":1,
     "playing":true,"playbackRate":1,"bundleIdentifier":"com.google.Chrome"}
    """)))
    #expect(info.title == "Test Song")
    #expect(info.artist == "Test Artist")
    #expect(info.duration == 200)
    #expect(info.elapsed == 42)
    #expect(info.isPlaying)
    #expect(info.bundleIdentifier == "com.google.Chrome")
    #expect(abs(info.timestamp.timeIntervalSince1970 - 1_791_879_369.902881) < 0.001)
}

@Test func emptyPayloadMeansNothingPlaying() {
    #expect(MediaRemoteAdapter.parse([:]) == nil)
}

@Test func browserMediaUsesParentApp() throws {
    let info = try #require(MediaRemoteAdapter.parse(payload("""
    {"title":"Video","playing":false,"bundleIdentifier":"com.apple.WebKit.GPU",
     "parentApplicationBundleIdentifier":"com.apple.Safari"}
    """)))
    #expect(info.bundleIdentifier == "com.apple.Safari")
    #expect(!info.isPlaying)
}

@Test func untaggedAudioFallsBackToAppName() throws {
    let info = try #require(MediaRemoteAdapter.parse(payload("""
    {"playing":true,"bundleIdentifier":"com.apple.QuickTimePlayerX","processIdentifier":1}
    """)))
    #expect(!info.title.isEmpty)
}
