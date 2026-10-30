import Observation

/// Whether the screen is being recorded, shared so other modules don't pop
/// up over a recording.
@MainActor
@Observable
public final class CaptureStatus {
    public static let shared = CaptureStatus()

    public var isRecording = false
}
