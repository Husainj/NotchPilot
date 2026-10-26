import AppKit
import Charts
import NotchShell
import SwiftUI

struct ScreenTimeView: View {
    let module: ScreenTimeModule

    var body: some View {
        if let nudge = module.nudge {
            NudgeView(module: module, nudge: nudge)
                .id(nudge.message)
        } else if let cheer = module.cheer {
            CheerView(text: cheer)
        } else {
            HStack(alignment: .top, spacing: 10) {
                SummaryCard(module: module).frame(width: 196)
                TopCard(module: module)
                WeekCard(module: module).frame(width: 200)
            }
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return seconds > 0 ? "<1m" : "0m" }
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SummaryCard: View {
    let module: ScreenTimeModule
    @Environment(\.notchAccent) private var accent

    var body: some View {
        let totals = module.todayTotals
        let split = module.split(totals)
        let total = split.focused + split.distracting
        let score = total > 0 ? Int((split.focused / total * 100).rounded()) : 100
        Card(title: "Today") {
            HStack(alignment: .firstTextBaseline) {
                Text(formatDuration(total))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                Spacer()
                Mascot(mood: mood(score: score), size: 34, animated: false)
                    .offset(y: 6)
            }
            SplitBar(focused: split.focused, distracting: split.distracting)
            VStack(alignment: .leading, spacing: 3) {
                Legend(color: .green, label: "Focused", value: formatDuration(split.focused))
                Legend(color: .orange, label: "Distracting", value: formatDuration(split.distracting))
            }
            Spacer(minLength: 0)
            if module.tracker.isOnBreak {
                HStack(spacing: 6) {
                    Text("☕ On a break").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("End") { module.endBreak() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
            } else {
                HStack {
                    Text("Score \(score)%")
                    Spacer()
                    Text("🔥 \(module.streakDays)d streak")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func mood(score: Int) -> Mood {
        if module.tracker.isOnBreak { return .sleepy }
        if module.tracker.level > 0 { return Mood.forLevel(module.tracker.level) }
        return score >= 70 ? .happy : .concerned
    }
}

private struct SplitBar: View {
    let focused: TimeInterval
    let distracting: TimeInterval

    var body: some View {
        GeometryReader { geo in
            let total = max(focused + distracting, 1)
            HStack(spacing: 2) {
                Capsule().fill(.green.opacity(0.85))
                    .frame(width: max(geo.size.width * focused / total - 1, focused > 0 ? 4 : 0))
                Capsule().fill(.orange)
                    .frame(width: max(geo.size.width * distracting / total - 1, distracting > 0 ? 4 : 0))
                if focused + distracting == 0 { Capsule().fill(.white.opacity(0.1)) }
            }
        }
        .frame(height: 7)
    }
}

private struct Legend: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

private struct TopCard: View {
    let module: ScreenTimeModule

    var body: some View {
        let top = module.todayTotals.sorted { $0.value > $1.value }.prefix(5)
        let maxValue = top.first?.value ?? 1
        Card(title: "Top today") {
            if top.isEmpty || maxValue < 30 {
                Text("Tracking has started. Your apps and sites will show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(top), id: \.key) { key, seconds in
                        UsageRow(module: module, key: key, seconds: seconds, fraction: seconds / maxValue)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct UsageRow: View {
    let module: ScreenTimeModule
    let key: String
    let seconds: TimeInterval
    let fraction: Double

    var body: some View {
        let distracting = module.isDistracting(key)
        HStack(spacing: 7) {
            Group {
                if let icon = module.icon(for: key) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "globe").foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 15, height: 15)
            Text(module.displayName(for: key))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(distracting ? Color.orange : Color.green.opacity(0.8))
                    .frame(width: max(geo.size.width * fraction, 3), height: 5)
                    .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 30, maxWidth: .infinity)
            .frame(height: 12)
            Text(formatDuration(seconds))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 46, alignment: .trailing)
            Menu {
                Button(distracting ? "Mark as focused" : "Mark as distracting") {
                    module.setDistracting(key, !distracting)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.white.opacity(0.5))
        }
        .contextMenu {
            Button(distracting ? "Mark as focused" : "Mark as distracting") {
                module.setDistracting(key, !distracting)
            }
        }
    }
}

private struct WeekCard: View {
    let module: ScreenTimeModule

    private struct Point: Identifiable {
        let date: Date
        let kind: String
        let minutes: Double
        var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
    }

    var body: some View {
        let days = module.week
        let points = days.flatMap {
            [Point(date: $0.date, kind: "Focused", minutes: $0.focused / 60),
             Point(date: $0.date, kind: "Distracting", minutes: $0.distracting / 60)]
        }
        Card(title: "This week") {
            Chart(points) { point in
                BarMark(x: .value("Day", point.date, unit: .day),
                        y: .value("Minutes", point.minutes))
                    .foregroundStyle(by: .value("Kind", point.kind))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(["Focused": Color.green.opacity(0.8), "Distracting": Color.orange])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .font(.system(size: 9))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel {
                        if let m = value.as(Double.self) {
                            Text(m >= 60 ? "\(Int(m / 60))h" : "\(Int(m))m").font(.system(size: 8))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct ScreenTimeSettingsView: View {
    @Bindable var module: ScreenTimeModule
    @State private var newSite = ""

    private var thresholds: [Int] {
        #if DEBUG
        [1, 10, 15, 20, 30, 45, 60, 90]
        #else
        [10, 15, 20, 30, 45, 60, 90]
        #endif
    }

    var body: some View {
        Form {
            Section("Nudges") {
                Toggle("Check in when I've been distracted too long", isOn: $module.nudgesEnabled)
                Picker("First check-in after", selection: $module.thresholdMinutes) {
                    ForEach(thresholds, id: \.self) { Text(minutes($0)).tag($0) }
                }
                Picker("Then every", selection: $module.repeatMinutes) {
                    ForEach([5, 10, 15, 20], id: \.self) { Text(minutes($0)).tag($0) }
                }
                Toggle("Stay quiet during calls", isOn: $module.quietDuringCalls)
                Toggle("Show the timer beside the notch", isOn: $module.showLiveActivity)
                Text("Short trips to other apps don't reset the timer. Two minutes away from distracting apps does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Daily goal") {
                Picker("Distracting time per day", selection: $module.dailyLimitMinutes) {
                    ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { Text(minutes($0)).tag($0) }
                }
                Text("Days under this goal build your streak.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Distracting websites") {
                Toggle("Track websites in browsers", isOn: $module.trackSites)
                Text("Reads only the site's domain from the active tab in Safari, Chrome, Arc, Brave, Edge and Vivaldi. macOS asks once per browser. Nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(module.categories.sites, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button { module.categories.sites.removeAll { $0 == site } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a site, e.g. news.ycombinator.com", text: $newSite)
                        .onSubmit(addSite)
                    Button("Add", action: addSite)
                        .disabled(domain(from: newSite) == nil)
                }
            }
            Section("Distracting apps") {
                ForEach(module.categories.apps, id: \.self) { bundleID in
                    HStack {
                        Text(module.displayName(for: UsageKey.app(bundleID)))
                        Spacer()
                        Button { module.categories.apps.removeAll { $0 == bundleID } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add a running app") {
                    ForEach(runningApps(), id: \.0) { bundleID, name in
                        Button(name) { module.categories.apps.append(bundleID) }
                    }
                }
            }
            Section {
                Button("Restore default lists") { module.categories = .standard }
            }
        }
        .formStyle(.grouped)
    }

    private func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min")
    }

    private func domain(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return UsageKey.normalizedDomain(fromURL: trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    private func addSite() {
        guard let site = domain(from: newSite) else { return }
        if !module.categories.sites.contains(site) { module.categories.sites.append(site) }
        newSite = ""
    }

    private func runningApps() -> [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      !module.categories.apps.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
