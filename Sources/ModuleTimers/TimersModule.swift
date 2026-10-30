import AppKit
import NotchShell
import SwiftUI

/// Countdown / Pomodoro / stopwatch. Times are stored as dates, so nothing
/// ticks in the background; views redraw with TimelineView only while visible.
@MainActor
@Observable
public final class TimersModule: NotchModule {
    public let id = "timers"
    public let title = "Timers"
    public let systemImage = "timer"

    enum Kind: Equatable {
        case timer, focus, rest

        var title: String {
            switch self {
            case .timer: "Timer"
            case .focus: "Focus"
            case .rest: "Break"
            }
        }

        var symbol: String {
            switch self {
            case .timer: "timer"
            case .focus: "brain.head.profile"
            case .rest: "cup.and.saucer.fill"
            }
        }
    }

    struct Countdown: Equatable {
        var kind: Kind
        var total: TimeInterval
        /// Set while running.
        var endDate: Date?
        /// Set while paused.
        var pausedRemaining: TimeInterval?

        func remaining(at date: Date) -> TimeInterval {
            if let pausedRemaining { return pausedRemaining }
            return max(endDate?.timeIntervalSince(date) ?? total, 0)
        }
    }

    private(set) var countdown: Countdown?
    /// Completed focus sessions today.
    private(set) var focusSessions = 0

    private(set) var stopwatchStart: Date?
    private(set) var stopwatchAccumulated: TimeInterval = 0
    private(set) var laps: [TimeInterval] = []

    var focusMinutes: Int { didSet { UserDefaults.standard.set(focusMinutes, forKey: "timers.focus") } }
    var breakMinutes: Int { didSet { UserDefaults.standard.set(breakMinutes, forKey: "timers.break") } }
    var autoContinue: Bool { didSet { UserDefaults.standard.set(autoContinue, forKey: "timers.autoContinue") } }
    var hydrationReminder: Bool {
        didSet {
            UserDefaults.standard.set(hydrationReminder, forKey: "timers.hydration")
            scheduleHydration()
        }
    }

    @ObservationIgnored private weak var context: NotchContext?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var hydrationTask: Task<Void, Never>?

    public init() {
        let d = UserDefaults.standard
        d.register(defaults: ["timers.focus": 25, "timers.break": 5, "timers.autoContinue": true, "timers.hydration": false])
        focusMinutes = d.integer(forKey: "timers.focus")
        breakMinutes = d.integer(forKey: "timers.break")
        autoContinue = d.bool(forKey: "timers.autoContinue")
        hydrationReminder = d.bool(forKey: "timers.hydration")
    }

    public func start(context: NotchContext) {
        self.context = context
        scheduleHydration()
    }

    public func stop() {
        finishTask?.cancel()
        hydrationTask?.cancel()
        context = nil
    }

    // MARK: - Countdown

    func startTimer(minutes: Double) { start(.timer, seconds: minutes * 60) }
    func startFocus() { start(.focus, seconds: Double(focusMinutes) * 60) }
    func startBreak() { start(.rest, seconds: Double(breakMinutes) * 60) }

    private func start(_ kind: Kind, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        countdown = Countdown(kind: kind, total: seconds, endDate: Date().addingTimeInterval(seconds))
        scheduleFinish()
    }

    func pauseOrResume() {
        guard var c = countdown else { return }
        if let remaining = c.pausedRemaining {
            c.endDate = Date().addingTimeInterval(remaining)
            c.pausedRemaining = nil
            countdown = c
            scheduleFinish()
        } else {
            c.pausedRemaining = c.remaining(at: Date())
            c.endDate = nil
            countdown = c
            finishTask?.cancel()
        }
    }

    func cancelCountdown() {
        finishTask?.cancel()
        countdown = nil
    }

    func addMinute() {
        guard var c = countdown else { return }
        c.total += 60
        if let paused = c.pausedRemaining { c.pausedRemaining = paused + 60 }
        if let end = c.endDate { c.endDate = end.addingTimeInterval(60) }
        countdown = c
        if c.endDate != nil { scheduleFinish() }
    }

    private func scheduleFinish() {
        finishTask?.cancel()
        guard let end = countdown?.endDate else { return }
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard let finished = countdown else { return }
        countdown = nil
        NSSound(named: "Glass")?.play()
        let message: String
        switch finished.kind {
        case .timer:
            message = "Time's up"
        case .focus:
            focusSessions += 1
            message = "Focus done — take a break"
            if autoContinue { startBreak() }
        case .rest:
            message = "Break over — back to it"
            if autoContinue { startFocus() }
        }
        announce(message, symbol: finished.kind.symbol)
    }

    private func announce(_ message: String, symbol: String) {
        context?.showTransient(CompactActivity(id: "timers-done", priority: 95, sideWidth: 120) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        } trailing: {
            Text(message)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }, for: .seconds(5))
    }

    // MARK: - Stopwatch

    var isStopwatchRunning: Bool { stopwatchStart != nil }

    func stopwatchElapsed(at date: Date) -> TimeInterval {
        stopwatchAccumulated + (stopwatchStart.map { date.timeIntervalSince($0) } ?? 0)
    }

    func toggleStopwatch() {
        if let start = stopwatchStart {
            stopwatchAccumulated += Date().timeIntervalSince(start)
            stopwatchStart = nil
        } else {
            stopwatchStart = Date()
        }
    }

    func lap() {
        guard isStopwatchRunning else { return }
        laps.insert(stopwatchElapsed(at: Date()), at: 0)
    }

    func resetStopwatch() {
        stopwatchStart = nil
        stopwatchAccumulated = 0
        laps = []
    }

    // MARK: - Hydration

    private func scheduleHydration() {
        hydrationTask?.cancel()
        guard hydrationReminder, context != nil else { return }
        hydrationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                guard !Task.isCancelled else { return }
                self?.announce("Drink some water", symbol: "drop.fill")
            }
        }
    }

    // MARK: - NotchModule

    public var compactActivity: CompactActivity? {
        if let countdown {
            return CompactActivity(id: "timers-countdown", priority: 20, sideWidth: 50) {
                Image(systemName: countdown.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(countdown.pausedRemaining != nil ? .white.opacity(0.5) : .white)
            } trailing: {
                TickingText { TimeFormat.clock(countdown.remaining(at: $0)) }
            }
        }
        if isStopwatchRunning {
            return CompactActivity(id: "timers-stopwatch", priority: 15, sideWidth: 50) {
                Image(systemName: "stopwatch").font(.system(size: 12, weight: .semibold))
            } trailing: {
                TickingText { TimeFormat.clock(self.stopwatchElapsed(at: $0)) }
            }
        }
        return nil
    }

    public func makeExpandedView() -> AnyView {
        AnyView(TimersView(module: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(TimersSettingsView(module: self))
    }
}

enum TimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func precise(_ seconds: TimeInterval) -> String {
        let cs = Int((seconds * 100).rounded(.down))
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }
}

private struct TickingText: View {
    let text: (Date) -> String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(context.date))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
    }
}

private struct TimersView: View {
    let module: TimersModule
    @State private var customMinutes = 15.0

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            countdownCard
            stopwatchCard
        }
    }

    private var countdownCard: some View {
        Card {
            if let countdown = module.countdown {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = countdown.remaining(at: context.date)
                    HStack(spacing: 14) {
                        ProgressRing(progress: countdown.total > 0 ? 1 - remaining / countdown.total : 0)
                            .frame(width: 70, height: 70)
                            .overlay(Image(systemName: countdown.kind.symbol).font(.system(size: 18)))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(countdown.kind.title.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(TimeFormat.clock(remaining))
                                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                            HStack(spacing: 8) {
                                SmallButton(countdown.pausedRemaining == nil ? "pause.fill" : "play.fill") { module.pauseOrResume() }
                                SmallButton("plus") { module.addMinute() }.help("Add 1 minute")
                                SmallButton("xmark") { module.cancelCountdown() }
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: module.startFocus) {
                        Label("Start Focus · \(module.focusMinutes) min", systemImage: "brain.head.profile")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle())
                    HStack(spacing: 6) {
                        ForEach([1, 5, 10, 25], id: \.self) { minutes in
                            Button("\(minutes)m") { module.startTimer(minutes: Double(minutes)) }
                                .buttonStyle(ChipButtonStyle())
                        }
                    }
                    HStack(spacing: 6) {
                        Stepper(value: $customMinutes, in: 1...180, step: 1) {
                            Text("\(Int(customMinutes)) min").font(.system(size: 12).monospacedDigit())
                        }
                        Button("Start") { module.startTimer(minutes: customMinutes) }
                            .buttonStyle(ChipButtonStyle())
                    }
                    if module.focusSessions > 0 {
                        Text("\(module.focusSessions) focus session\(module.focusSessions == 1 ? "" : "s") today")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    private var stopwatchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: module.isStopwatchRunning ? 0.05 : 3600)) { context in
                    Text(TimeFormat.precise(module.stopwatchElapsed(at: context.date)))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                }
                HStack(spacing: 8) {
                    SmallButton(module.isStopwatchRunning ? "pause.fill" : "play.fill") { module.toggleStopwatch() }
                    SmallButton("flag.fill") { module.lap() }.disabled(!module.isStopwatchRunning).help("Lap")
                    SmallButton("arrow.counterclockwise") { module.resetStopwatch() }.help("Reset")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(module.laps.enumerated()), id: \.offset) { index, lap in
                            HStack {
                                Text("Lap \(module.laps.count - index)")
                                Spacer()
                                Text(TimeFormat.precise(lap)).monospacedDigit()
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ProgressRing: View {
    let progress: Double
    @Environment(\.notchAccent) private var accent

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
    }
}

private struct SmallButton: View {
    let symbol: String
    let action: () -> Void

    init(_ symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 24)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.island)
    }
}

private struct AccentButtonStyle: ButtonStyle {
    @Environment(\.notchAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 7)
            .foregroundStyle(.black)
            .background(accent.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.12), in: Capsule())
    }
}

private struct TimersSettingsView: View {
    @Bindable var module: TimersModule

    var body: some View {
        Form {
            Stepper("Focus length: \(module.focusMinutes) min", value: $module.focusMinutes, in: 5...120, step: 5)
            Stepper("Break length: \(module.breakMinutes) min", value: $module.breakMinutes, in: 1...60)
            Toggle("Start the next focus/break automatically", isOn: $module.autoContinue)
            Toggle("Remind me to drink water every 30 minutes", isOn: $module.hydrationReminder)
        }
        .formStyle(.grouped)
    }
}
