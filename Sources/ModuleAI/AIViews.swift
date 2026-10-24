import Charts
import NotchShell
import SwiftUI

struct AIView: View {
    let module: AIModule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LimitsCard(module: module)
            UsageCard(snapshot: module.snapshot)
            SessionsCard(module: module)
        }
        .onAppear { module.viewAppeared() }
        .onDisappear { module.viewDisappeared() }
    }
}

// MARK: - Cards

private struct AICard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

private struct LimitsCard: View {
    let module: AIModule
    @State private var showCodex = false

    var body: some View {
        let snapshot = module.snapshot
        let both = snapshot.hasClaude && snapshot.hasCodex
        AICard(title: "Limits") {
            if both {
                Picker("", selection: $showCodex) {
                    Text("Claude").tag(false)
                    Text("Codex").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
            }
            if snapshot.hasCodex && (showCodex || !snapshot.hasClaude) {
                CodexLimitsView(limits: snapshot.codexLimits)
            } else if snapshot.hasClaude {
                ClaudeWindowView(block: snapshot.currentBlock, peak: snapshot.peakBlockCost)
            } else {
                Text("No Claude Code or Codex usage found on this Mac yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct ClaudeWindowView: View {
    let block: UsageBlock?
    let peak: Double
    @Environment(\.notchAccent) private var accent

    var body: some View {
        if let block {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                let elapsed = now.timeIntervalSince(block.start) / UsageBlock.length
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                            Circle()
                                .trim(from: 0, to: min(max(elapsed, 0), 1))
                                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "hourglass").font(.system(size: 13, weight: .semibold))
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resets in")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            Text(UsageFormat.duration(block.end.timeIntervalSince(now)))
                                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                            Text("at \(block.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Text("\(UsageFormat.dollars(block.cost)) · \(UsageFormat.tokens(block.usage.total)) tok · \(UsageFormat.dollars(block.burnRate(at: now)))/h")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if peak > 0 {
                        MeterRow(label: "vs busiest window", fraction: block.cost / peak)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                Text("No active 5-hour window")
                    .font(.system(size: 12, weight: .semibold))
                Text("Your next Claude Code message starts a fresh one.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct CodexLimitsView: View {
    let limits: CodexLimits?

    var body: some View {
        if let limits, limits.primary != nil || limits.secondary != nil {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array([limits.primary, limits.secondary].compactMap { $0 }.enumerated()), id: \.offset) { _, limit in
                        let reset = limit.resetsAt.map { $0.timeIntervalSince(context.date) }
                        let expired = (reset ?? 1) <= 0
                        VStack(alignment: .leading, spacing: 3) {
                            MeterRow(label: "\(limit.label) limit", fraction: expired ? 0 : limit.usedPercent / 100)
                            Text(expired ? "Reset" : reset.map { "Resets in \(UsageFormat.duration($0))" } ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Text("Updated \(ElapsedFormat.ago(limits.observedAt, now: context.date))")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        } else {
            Text("Codex reports its limits after your next message.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct MeterRow: View {
    let label: String
    let fraction: Double
    @Environment(\.notchAccent) private var accent

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%").monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(clamped > 0.9 ? Color.red : clamped > 0.7 ? Color.orange : accent)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 5)
        }
    }
}

private struct UsageCard: View {
    let snapshot: UsageSnapshot
    @Environment(\.notchAccent) private var accent

    var body: some View {
        let showCost = snapshot.hasClaude
        AICard(title: "Today") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showCost {
                        Text(UsageFormat.dollars(snapshot.todayCost))
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        Text("\(UsageFormat.tokens(snapshot.today.total)) tok")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    } else {
                        Text(UsageFormat.tokens(snapshot.codexTodayTokens))
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        Text("tokens").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                if showCost, !snapshot.todayByModel.isEmpty {
                    Text(snapshot.todayByModel.prefix(2)
                        .map { "\(UsageFormat.modelName($0.model)) \(UsageFormat.dollars($0.cost))" }
                        .joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if showCost, snapshot.codexTodayTokens > 0 {
                    Text("Codex \(UsageFormat.tokens(snapshot.codexTodayTokens)) tok")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Chart(snapshot.days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day),
                            y: .value("Usage", showCost ? day.claudeCost : Double(day.codexTokens)))
                        .foregroundStyle(Calendar.current.isDateInToday(day.day) ? accent : accent.opacity(0.45))
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
                if showCost {
                    Text("7 days \(UsageFormat.dollars(snapshot.weekCost)) · API prices")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
}

private struct SessionsCard: View {
    let module: AIModule

    var body: some View {
        let sessions = module.board.sorted
        AICard(title: "Sessions") {
            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if module.anyConnected {
                        Text("No active sessions. Start Claude Code, Codex or Cursor's agent and it shows up here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    } else {
                        Text("See when an agent is working, needs approval, or is done.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                        ConnectButtons(module: module)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sessions) { session in
                            SessionRow(session: session, module: module)
                        }
                    }
                }
                if module.isKeepingAwake {
                    Label("Keeping your Mac awake", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }
}

private struct ConnectButtons: View {
    let module: AIModule

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(AgentKind.allCases, id: \.self) { agent in
                if module.hookStatus[agent] == .disconnected {
                    Button {
                        module.setConnected(agent, true)
                    } label: {
                        Label("Connect \(agent.name)", systemImage: "link")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let error = module.hookError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if !AgentKind.allCases.contains(where: { module.hookStatus[$0] == .disconnected }) && module.hookError == nil {
                Text("Install Claude Code, Codex or Cursor first.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let module: AIModule
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agent.symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(color.opacity(0.22), in: Circle())
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: session.status == .working)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(now: context.date))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(session.status == .needsInput ? .orange : .white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if hovering && session.status != .working && session.status != .needsInput {
                Button { module.dismiss(session) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(5)
        .background(.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { module.focus(session) }
        .help(session.message ?? "Click to switch to \(session.agent.name)")
    }

    private var color: Color {
        switch session.status {
        case .needsInput: .orange
        case .working: .blue
        case .done: .green
        case .failed: .red
        case .idle: .gray
        }
    }

    private func detail(now: Date) -> String {
        let name = session.agent.shortName
        switch session.status {
        case .working: return "\(name) · working \(ElapsedFormat.clock(now.timeIntervalSince(session.since)))"
        case .needsInput: return session.message ?? "\(name) needs your approval"
        case .done: return "\(name) · done \(ElapsedFormat.ago(session.since, now: now))"
        case .failed: return "\(name) · failed \(ElapsedFormat.ago(session.since, now: now))"
        case .idle: return "\(name) · ready"
        }
    }
}

// MARK: - Settings

struct AISettingsView: View {
    @Bindable var module: AIModule

    var body: some View {
        Form {
            Section {
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    AgentConnectionRow(agent: agent, module: module)
                }
                if let error = module.hookError {
                    Text(error).foregroundStyle(.orange)
                }
            } header: {
                Text("Live sessions")
            } footer: {
                Text("Connecting adds a small hook (~/.notch/notch-agent-hook) to the agent's config, and keeps a backup of the original file. Running sessions pick it up after a restart. Nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Alerts") {
                Toggle("When an agent needs approval or input", isOn: $module.alertOnNeedsInput)
                Toggle("When an agent finishes", isOn: $module.alertOnFinish)
                Toggle("Play sounds", isOn: $module.playSounds)
                Toggle("Stay quiet if the agent's app is already in front", isOn: $module.quietWhenFrontmost)
                Toggle("When the Claude 5-hour window resets", isOn: $module.alertOnWindowReset)
            }
            Section {
                Toggle("Keep the Mac awake while an agent is working", isOn: $module.keepAwakeWhileWorking)
                Stepper("Stop after \(module.keepAwakeMaxHours) hour\(module.keepAwakeMaxHours == 1 ? "" : "s") of continuous work",
                        value: $module.keepAwakeMaxHours, in: 1...12)
                    .disabled(!module.keepAwakeWhileWorking)
            } header: {
                Text("Keep awake")
            } footer: {
                Text("Stops idle sleep only; closing the lid still sleeps the Mac. Screen and battery limits are in the System settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Usage is read from Claude Code's and Codex's local logs. Claude costs use API list prices, so Pro and Max subscribers can see how heavily they're using their plan. They are not a bill. The 5-hour window is estimated from your message times; Codex limits come straight from Codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { module.refreshHookStatus() }
    }
}

private struct AgentConnectionRow: View {
    let agent: AgentKind
    let module: AIModule

    var body: some View {
        let status = module.hookStatus[agent] ?? .notInstalled
        HStack {
            Label(agent.name, systemImage: agent.symbol)
            Spacer()
            switch status {
            case .notInstalled:
                Text("Not installed").foregroundStyle(.secondary)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Button("Disconnect") { module.setConnected(agent, false) }
            case .disconnected:
                Button("Connect") { module.setConnected(agent, true) }
            case .conflict(let message):
                Text("Can't connect").foregroundStyle(.orange).help(message)
            }
        }
    }
}
