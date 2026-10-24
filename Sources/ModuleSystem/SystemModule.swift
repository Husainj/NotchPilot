import AppKit
import NotchShell
import SwiftUI

@MainActor
@Observable
public final class SystemModule: NotchModule {
    public let id = "system"
    public let title = "System"
    public let systemImage = "slider.horizontal.3"

    let battery = BatteryMonitor()
    private(set) var volume: Float = AudioController.volume ?? 0
    private(set) var isMuted = AudioController.isMuted
    private(set) var brightness: Float? = BrightnessController.brightness

    var replaceHUD: Bool {
        didSet {
            UserDefaults.standard.set(replaceHUD, forKey: "system.replaceHUD")
            updateKeyTap()
        }
    }
    var showChargingActivity: Bool {
        didSet { UserDefaults.standard.set(showChargingActivity, forKey: "system.showCharging") }
    }
    /// True when HUD replacement is on but Accessibility hasn't been granted.
    private(set) var needsAccessibility = false

    @ObservationIgnored private let keyTap = MediaKeyTap()
    @ObservationIgnored private weak var context: NotchContext?
    @ObservationIgnored private var trustPoll: Task<Void, Never>?

    public init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["system.replaceHUD": false, "system.showCharging": true])
        replaceHUD = defaults.bool(forKey: "system.replaceHUD")
        showChargingActivity = defaults.bool(forKey: "system.showCharging")
    }

    public func start(context: NotchContext) {
        self.context = context
        battery.onPluggedIn = { [weak self] in self?.showChargingHUD() }
        battery.start()
        keyTap.handler = { [weak self] key, fine in self?.handle(key, fine: fine) ?? false }
        updateKeyTap()
        KeepAwake.shared.onLowBatteryStop = { [weak self] in
            self?.context?.showTransient(CompactActivity(id: "awake-stopped", priority: 90, sideWidth: 110) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
            } trailing: {
                Text("Low battery, sleep allowed")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }, for: .seconds(5))
        }
    }

    public func stop() {
        KeepAwake.shared.release(Self.manualAwakeID)
        battery.stop()
        keyTap.stop()
        trustPoll?.cancel()
    }

    func refreshLevels() {
        volume = AudioController.volume ?? 0
        isMuted = AudioController.isMuted
        brightness = BrightnessController.brightness
    }

    func setVolume(_ value: Float) {
        AudioController.setVolume(value)
        refreshLevels()
    }

    func setBrightness(_ value: Float) {
        BrightnessController.setBrightness(value)
        refreshLevels()
    }

    // MARK: - HUD replacement

    private func updateKeyTap() {
        trustPoll?.cancel()
        guard replaceHUD else {
            keyTap.stop()
            needsAccessibility = false
            return
        }
        if keyTap.start() {
            needsAccessibility = false
            return
        }
        needsAccessibility = true
        MediaKeyTap.requestTrust()
        // Start the tap as soon as the user grants access in System Settings.
        trustPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.replaceHUD else { return }
                if self.keyTap.start() {
                    self.needsAccessibility = false
                    return
                }
            }
        }
    }

    private func handle(_ key: MediaKeyTap.Key, fine: Bool) -> Bool {
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard AudioController.volume != nil else { return false } // let macOS handle fixed-volume devices
            switch key {
            case .volumeUp: AudioController.setVolume((AudioController.volume ?? 0) + step)
            case .volumeDown: AudioController.setVolume((AudioController.volume ?? 0) - step)
            default: AudioController.setMuted(!AudioController.isMuted)
            }
            refreshLevels()
            showLevelHUD(symbol: volumeSymbol, level: isMuted ? 0 : volume)
        case .brightnessUp, .brightnessDown:
            guard let current = BrightnessController.brightness else { return false }
            BrightnessController.setBrightness(current + (key == .brightnessUp ? step : -step))
            refreshLevels()
            showLevelHUD(symbol: "sun.max.fill", level: brightness ?? 0)
        }
        return true
    }

    var volumeSymbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.wave.1.fill" }
        if volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func showLevelHUD(symbol: String, level: Float) {
        context?.showTransient(CompactActivity(id: "hud", priority: 100, sideWidth: 64) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        } trailing: {
            LevelBar(level: level)
                .frame(width: 50, height: 5)
        }, for: .seconds(1.5))
    }

    private func showChargingHUD() {
        guard showChargingActivity else { return }
        let percent = battery.percent
        context?.showTransient(CompactActivity(id: "charging", priority: 90, sideWidth: 56) {
            Text("Charging")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
        } trailing: {
            HStack(spacing: 3) {
                Text("\(percent)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                Image(systemName: "bolt.fill").font(.system(size: 10))
            }
            .foregroundStyle(.green)
        }, for: .seconds(3))
    }

    // MARK: - Keep awake

    static let manualAwakeID = "manual"

    var manualAwake: KeepAwake.Hold? { KeepAwake.shared.hold(for: Self.manualAwakeID) }

    /// nil minutes = until turned off.
    func keepAwake(minutes: Int?) {
        KeepAwake.shared.hold(Self.manualAwakeID, label: "Keep awake",
                              until: minutes.map { Date().addingTimeInterval(Double($0) * 60) })
    }

    func stopKeepAwake() {
        KeepAwake.shared.release(Self.manualAwakeID)
    }

    public var compactActivity: CompactActivity? {
        guard let hold = manualAwake else { return nil }
        return CompactActivity(id: "awake-manual", priority: 5, sideWidth: 50) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12, weight: .semibold))
        } trailing: {
            if let until = hold.until {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AwakeFormat.remaining(until.timeIntervalSince(context.date)))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            } else {
                Image(systemName: "infinity").font(.system(size: 12, weight: .semibold))
            }
        }
    }

    // MARK: - Views

    public func makeExpandedView() -> AnyView {
        AnyView(SystemExpandedView(module: self))
    }

    public func makeHeaderAccessory() -> AnyView? {
        AnyView(HStack(spacing: 8) {
            AwakeBadge()
            BatteryBadge(battery: battery)
        })
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(SystemSettingsView(module: self))
    }
}

struct LevelBar: View {
    @Environment(\.notchAccent) private var accent
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(accent).frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct BatteryBadge: View {
    let battery: BatteryMonitor

    var body: some View {
        if battery.hasBattery {
            HStack(spacing: 4) {
                Text("\(battery.percent)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Image(systemName: battery.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(battery.isCharging ? .green : (battery.percent <= 20 ? .red : .white))
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct SystemExpandedView: View {
    @Bindable var module: SystemModule

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                LevelSlider(symbol: module.volumeSymbol,
                            value: Binding(get: { module.isMuted ? 0 : module.volume }, set: { module.setVolume($0) }))
                if module.brightness != nil {
                    LevelSlider(symbol: "sun.max.fill",
                                value: Binding(get: { module.brightness ?? 0 }, set: { module.setBrightness($0) }))
                }
                if module.battery.hasBattery {
                    BatteryRow(battery: module.battery)
                }
                KeepAwakeRow(module: module)
                if module.needsAccessibility {
                    Button("Allow Accessibility for the custom HUD") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
        .onAppear { module.refreshLevels() }
    }
}

private struct LevelSlider: View {
    @Environment(\.notchAccent) private var accent
    let symbol: String
    @Binding var value: Float

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 20)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(accent).frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value = Float(min(max(drag.location.x / geo.size.width, 0), 1))
                })
            }
            .frame(height: 6)
        }
        .frame(height: 18)
    }
}

private struct BatteryRow: View {
    let battery: BatteryMonitor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: battery.symbolName)
                .font(.system(size: 12))
                .frame(width: 20)
                .foregroundStyle(battery.isCharging ? .green : .white)
            Text("\(battery.percent)%").monospacedDigit()
            if let minutes = battery.timeRemaining {
                Text(battery.isCharging ? "· full in \(Self.format(minutes))" : "· \(Self.format(minutes)) left")
                    .foregroundStyle(.white.opacity(0.5))
            } else if battery.isPluggedIn && !battery.isCharging {
                Text("· plugged in").foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    static func format(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct SystemSettingsView: View {
    @Bindable var module: SystemModule
    @Bindable private var awake = KeepAwake.shared

    var body: some View {
        Form {
            Toggle("Replace the volume & brightness HUD", isOn: $module.replaceHUD)
            if module.needsAccessibility {
                Text("\(AppInfo.name) needs Accessibility permission to intercept the volume and brightness keys. Enable \(AppInfo.name) in System Settings → Privacy & Security → Accessibility. If you just updated \(AppInfo.name), remove it from the list and add it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            Toggle("Show charging animation", isOn: $module.showChargingActivity)
            Section("Keep awake") {
                Toggle("Let the screen turn off while the Mac stays awake", isOn: $awake.allowDisplaySleep)
                Picker("On battery, stop below", selection: $awake.minimumBattery) {
                    Text("Never").tag(0)
                    ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                Text("Closing the lid still puts the Mac to sleep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

enum AwakeFormat {
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 0)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// Shown in the open island's header whenever anything is keeping the Mac awake.
private struct AwakeBadge: View {
    var body: some View {
        let awake = KeepAwake.shared
        if awake.isActive {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .help("Keeping your Mac awake: \(awake.summary ?? "")")
        }
    }
}

private struct KeepAwakeRow: View {
    let module: SystemModule
    @Environment(\.notchAccent) private var accent

    private static let options: [(label: String, minutes: Int?)] = [("30m", 30), ("1h", 60), ("2h", 120), ("∞", nil)]

    var body: some View {
        let hold = module.manualAwake
        HStack(spacing: 6) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12))
                .frame(width: 20)
                .foregroundStyle(hold != nil ? accent : .white)
            Text("Keep awake")
                .font(.system(size: 12, weight: .medium))
            if let until = hold?.until {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AwakeFormat.remaining(until.timeIntervalSince(context.date)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 4)
            ForEach(Self.options, id: \.label) { option in
                let selected = hold != nil && optionMatches(option.minutes, hold)
                Button(option.label) { module.keepAwake(minutes: option.minutes) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(selected ? accent.opacity(0.3) : .white.opacity(0.12), in: Capsule())
            }
            if hold != nil {
                Button("Off") { module.stopKeepAwake() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
    }

    private func optionMatches(_ minutes: Int?, _ hold: KeepAwake.Hold?) -> Bool {
        minutes == nil ? hold?.until == nil : false
    }
}
