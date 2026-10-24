import EventKit
import NotchShell
import Observation
import SwiftUI

struct AgendaEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    /// Zoom / Meet / Teams / … link found in the event, if any.
    var joinURL: URL?
}

struct ReminderItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let due: Date?
    let color: Color
}

/// Events (next 7 days) and open reminders via EventKit.
@MainActor
@Observable
final class CalendarStore {
    private(set) var events: [AgendaEvent] = []
    private(set) var reminders: [ReminderItem] = []
    private(set) var eventAccess = EKEventStore.authorizationStatus(for: .event)
    private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
    /// Updated every minute so time-based UI (e.g. "starts in 5m") refreshes.
    private(set) var now = Date()

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    var hasEventAccess: Bool { eventAccess == .fullAccess }
    var hasReminderAccess: Bool { reminderAccess == .fullAccess }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.reload()
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        refreshTask?.cancel()
    }

    func requestEventAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            reload()
        }
    }

    func requestReminderAccess() {
        Task {
            _ = try? await store.requestFullAccessToReminders()
            reload()
        }
    }

    /// Starts within the next 10 minutes (or is starting right now).
    var imminentEvent: AgendaEvent? {
        events.first { !$0.isAllDay && $0.start.timeIntervalSince(now) <= 600 && $0.start.timeIntervalSince(now) > -60 }
    }

    // MARK: - Reminders

    func complete(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        reminders.removeAll { $0.id == id }
    }

    func addReminder(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let calendar = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = calendar
        try? store.save(reminder, commit: true)
        reload()
    }

    // MARK: - Loading

    private func reload() {
        now = Date()
        eventAccess = EKEventStore.authorizationStatus(for: .event)
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        loadEvents()
        loadReminders()
    }

    private func loadEvents() {
        guard hasEventAccess else { events = []; return }
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? now
        events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                AgendaEvent(id: (event.calendarItemIdentifier) + "\(event.startDate.timeIntervalSince1970)",
                            title: event.title ?? "Untitled",
                            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                            color: Color(nsColor: event.calendar?.color ?? .systemBlue),
                            joinURL: MeetingLink.find(url: event.url, location: event.location,
                                                      notes: event.hasNotes ? event.notes : nil))
            }
    }

    private func loadReminders() {
        guard hasReminderAccess else { reminders = []; return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] result in
            // Map to Sendable values before leaving EventKit's queue.
            let items = (result ?? []).map { reminder in
                ReminderItem(id: reminder.calendarItemIdentifier,
                             title: reminder.title ?? "Untitled",
                             due: reminder.dueDateComponents?.date,
                             color: Color(nsColor: reminder.calendar?.color ?? .systemOrange))
            }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            Task { @MainActor in self?.reminders = Array(items.prefix(30)) }
        }
    }
}
