import NotchShell
import SwiftUI

/// The mascot's check-in: message, actions and the tasks waiting for you.
struct NudgeView: View {
    let module: ScreenTimeModule
    let nudge: ScreenTimeModule.ActiveNudge
    @Environment(\.notchAccent) private var accent
    @State private var dropped = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Mascot(mood: nudge.mood, size: 104)
                .offset(y: dropped ? 0 : -160)
                .frame(width: 104)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(nudge.level == 0 ? "BREAK'S OVER" : "PILOT CHECK-IN")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    if nudge.level > 0 {
                        HStack(spacing: 3) {
                            ForEach(1...UsageTracker.maxLevel, id: \.self) { i in
                                Circle()
                                    .fill(i <= nudge.level ? levelColor : .white.opacity(0.15))
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                }
                Text(nudge.message)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if nudge.level == 0 {
                        PrimaryButton(title: "Let's go", color: accent) { module.backToWork() }
                        GhostButton(title: "Not yet") { module.dismiss() }
                    } else {
                        PrimaryButton(title: "Back to work", color: accent) { module.backToWork() }
                        GhostButton(title: "5 more min") { module.snooze() }
                        GhostButton(title: "Taking a break") { module.takeBreak() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            TasksCard(module: module)
                .frame(width: 210)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { dropped = true }
        }
    }

    private var levelColor: Color {
        switch nudge.level {
        case 1: .yellow
        case 2: .orange
        default: .red
        }
    }
}

/// "Back to work!" with a happy mascot, shown briefly after choosing it.
struct CheerView: View {
    let text: String
    @Environment(\.notchAccent) private var accent

    var body: some View {
        HStack(spacing: 16) {
            Mascot(mood: .happy, size: 104)
            Text(text)
                .font(.system(size: 22, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TasksCard: View {
    let module: ScreenTimeModule
    @Environment(\.notchAccent) private var accent

    var body: some View {
        let tasks = module.tasks
        VStack(alignment: .leading, spacing: 7) {
            Text("TODAY'S TASKS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            if !module.hasReminderAccess {
                Text("Connect Apple Reminders to see your to-dos here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Connect Reminders") { module.openCalendar() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            } else if tasks.isEmpty {
                Text("No open tasks. Pick one thing you've been putting off 💪")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(tasks.prefix(3)) { task in
                    TaskRow(task: task) { module.completeTask(task.id) }
                }
            }
            Spacer(minLength: 0)
            if let meeting = module.nextMeeting, meeting.start > Date() {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .foregroundStyle(accent)
                    Text(meeting.title).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(startsIn(meeting.start))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 10.5))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func startsIn(_ date: Date) -> String {
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes < 60 { return "in \(max(minutes, 0))m" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct TaskRow: View {
    let task: FocusTask
    let complete: () -> Void
    @State private var done = false

    var body: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { done = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    complete()
                }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(done ? .green : .white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Mark as done")
            Text(task.title)
                .font(.system(size: 11.5, weight: .medium))
                .strikethrough(done)
                .lineLimit(1)
            Spacer(minLength: 2)
            if task.isOverdue() {
                Text("overdue").font(.system(size: 9, weight: .semibold)).foregroundStyle(.red)
            } else if let due = task.due, Calendar.current.isDateInToday(due) {
                Text("today").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
            }
        }
    }
}

struct PrimaryButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(.black)
                .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct GhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(.white.opacity(0.85))
                .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
