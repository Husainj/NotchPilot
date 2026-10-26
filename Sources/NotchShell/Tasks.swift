import Foundation

/// A to-do shared between modules (from Apple Reminders, via the Calendar module).
public struct FocusTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let due: Date?

    public init(id: String, title: String, due: Date?) {
        self.id = id
        self.title = title
        self.due = due
    }

    public func isOverdue(now: Date = Date()) -> Bool {
        guard let due else { return false }
        return due < Calendar.current.startOfDay(for: now)
    }
}
