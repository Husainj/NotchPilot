import NotchShell
import SwiftUI

@MainActor
@Observable
public final class CalendarModule: NotchModule {
    public let id = "calendar"
    public let title = "Calendar"
    public let systemImage = "calendar"

    let store = CalendarStore()

    public init() {}

    public func start(context: NotchContext) { store.start() }
    public func stop() { store.stop() }

    public func makeExpandedView() -> AnyView {
        AnyView(CalendarView(store: store))
    }

    /// Timed events that haven't ended, soonest first (for the meeting module).
    public var upcomingMeetings: [JoinableMeeting] {
        store.events.filter { !$0.isAllDay }.map {
            JoinableMeeting(id: $0.id, title: $0.title, start: $0.start, end: $0.end, joinURL: $0.joinURL)
        }
    }

    /// Open reminders worth doing now: overdue and due today first, then
    /// undated, then upcoming (for the Screen Time nudge).
    public var focusTasks: [FocusTask] {
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let items = store.reminders
        let now = items.filter { ($0.due ?? .distantFuture) < endOfToday }
        let undated = items.filter { $0.due == nil }
        let later = items.filter { ($0.due.map { $0 >= endOfToday }) ?? false }
        return (now + undated + later).prefix(5).map { FocusTask(id: $0.id, title: $0.title, due: $0.due) }
    }

    public var hasReminderAccess: Bool { store.hasReminderAccess }

    public func completeTask(_ id: String) { store.complete(id) }

    /// "Meeting in 5m" beside the notch shortly before an event.
    public var compactActivity: CompactActivity? {
        guard let event = store.imminentEvent else { return nil }
        let minutes = max(Int((event.start.timeIntervalSince(store.now) / 60).rounded(.up)), 0)
        return CompactActivity(id: "calendar-\(event.id)", priority: 30, sideWidth: 44) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(event.color)
        } trailing: {
            Text(minutes == 0 ? "now" : "\(minutes)m")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
    }
}

private struct CalendarView: View {
    let store: CalendarStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AgendaColumn(store: store)
                .frame(maxWidth: .infinity, alignment: .leading)
            RemindersColumn(store: store)
                .frame(width: 230, alignment: .leading)
        }
    }
}

private struct AgendaColumn: View {
    let store: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header("Next 7 days")
            if !store.hasEventAccess {
                AccessPrompt(title: "Show calendar events", denied: store.eventAccess == .denied || store.eventAccess == .restricted,
                             pane: "Privacy_Calendars", action: store.requestEventAccess)
            } else if store.events.isEmpty {
                Text("Nothing scheduled").font(.caption).foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedByDay(store.events), id: \.day) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dayTitle(group.day))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.45))
                                ForEach(group.events) { EventRow(event: $0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func groupedByDay(_ events: [AgendaEvent]) -> [(day: Date, events: [AgendaEvent])] {
        let groups = Dictionary(grouping: events) { Calendar.current.startOfDay(for: max($0.start, store.now)) }
        return groups.keys.sorted().map { ($0, groups[$0]!) }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(day) { return "TOMORROW" }
        return day.formatted(.dateTime.weekday(.wide).day().month()).uppercased()
    }
}

private struct EventRow: View {
    let event: AgendaEvent

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(event.isAllDay ? "All day"
                     : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            if let url = event.joinURL, event.end > Date() {
                JoinButton(url: url)
            }
        }
    }
}

struct JoinButton: View {
    let url: URL
    @Environment(\.notchAccent) private var accent

    var body: some View {
        Button { MeetingLink.join(url) } label: {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(.black)
                .background(accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Join on \(MeetingLink.service(for: url)?.name ?? "the call")")
    }
}

private struct RemindersColumn: View {
    let store: CalendarStore
    @State private var newTitle = ""
    @Environment(\.notchAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header("Reminders")
            if !store.hasReminderAccess {
                AccessPrompt(title: "Show reminders", denied: store.reminderAccess == .denied || store.reminderAccess == .restricted,
                             pane: "Privacy_Reminders", action: store.requestReminderAccess)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(accent)
                    TextField("Add a reminder", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            store.addReminder(newTitle)
                            newTitle = ""
                        }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(store.reminders) { reminder in
                            HStack(alignment: .top, spacing: 7) {
                                Button { store.complete(reminder.id) } label: {
                                    Image(systemName: "circle").foregroundStyle(reminder.color)
                                }
                                .buttonStyle(.plain)
                                .help("Mark as done")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(reminder.title).font(.system(size: 12)).lineLimit(2)
                                    if let due = reminder.due {
                                        Text(due.formatted(date: .abbreviated, time: .omitted))
                                            .font(.system(size: 9))
                                            .foregroundStyle(due < Date() ? .red : .white.opacity(0.45))
                                    }
                                }
                            }
                        }
                        if store.reminders.isEmpty {
                            Text("All done 🎉").font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
        }
    }
}

private struct Header: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
    }
}

private struct AccessPrompt: View {
    let title: String
    let denied: Bool
    let pane: String
    let action: () -> Void

    var body: some View {
        if denied {
            Button("Access is off — open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
            .buttonStyle(.link)
            .font(.caption)
        } else {
            Button(title, action: action).buttonStyle(.link).font(.caption)
        }
    }
}
