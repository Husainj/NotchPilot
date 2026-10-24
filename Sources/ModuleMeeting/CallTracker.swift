import Foundation

/// Turns noisy "mic/camera in use" signals into call start/end.
/// A short dictation or Siri request shouldn't count, and a brief device
/// switch mid-call shouldn't end the call.
struct CallTracker: Equatable, Sendable {
    enum Transition: Equatable, Sendable { case started, ended(duration: TimeInterval) }

    static let startDelay: TimeInterval = 4
    static let endDelay: TimeInterval = 6

    private(set) var callStart: Date?
    private var activeSince: Date?
    private var inactiveSince: Date?

    var isInCall: Bool { callStart != nil }

    mutating func update(active: Bool, now: Date) -> Transition? {
        if active {
            inactiveSince = nil
            if activeSince == nil { activeSince = now }
            if callStart == nil, let since = activeSince, now.timeIntervalSince(since) >= Self.startDelay {
                callStart = since
                return .started
            }
        } else {
            activeSince = nil
            guard let start = callStart else { return nil }
            if inactiveSince == nil { inactiveSince = now }
            if let since = inactiveSince, now.timeIntervalSince(since) >= Self.endDelay {
                callStart = nil
                inactiveSince = nil
                return .ended(duration: since.timeIntervalSince(start))
            }
        }
        return nil
    }

    /// When the tracker next needs a tick to resolve a pending start or end.
    var pendingDeadline: Date? {
        if callStart == nil, let since = activeSince { return since.addingTimeInterval(Self.startDelay) }
        if callStart != nil, let since = inactiveSince { return since.addingTimeInterval(Self.endDelay) }
        return nil
    }
}
