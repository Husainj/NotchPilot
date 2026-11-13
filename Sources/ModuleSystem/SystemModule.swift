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
    private(set) var keyboardBrightness: Float? = KeyboardBacklightController.brightness

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
        keyboardBrightness = KeyboardBacklightController.brightness
    }

    func setKeyboardBrightness(_ value: Float) {
        KeyboardBacklightController.setBrightness(value)
        refreshLevels()
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
        case .keyboardUp, .keyboardDown:
            guard let current = KeyboardBacklightController.brightness else { return false }
            KeyboardBacklightController.setBrightness(current + (key == .keyboardUp ? step : -step))
            refreshLevels()
            showLevelHUD(symbol: "light.max", level: keyboardBrightness ?? 0)
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

private enum SystemColors {
    static let volume = Color(red: 1.0, green: 0.4, blue: 0.6)
    static let display = Color(red: 1.0, green: 0.78, blue: 0.25)
    static let keyboard = Color(red: 0.35, green: 0.85, blue: 1.0)
    static let battery = Color(red: 0.3, green: 0.88, blue: 0.5)
    static let lowBattery = Color(red: 1.0, green: 0.35, blue: 0.35)
    static let awake = Color(red: 0.7, green: 0.5, blue: 1.0)
}

private struct SystemExpandedView: View {
    @Bindable var module: SystemModule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IslandCard(tint: SystemColors.volume, padding: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    LevelSlider(title: "Volume", symbol: module.volumeSymbol, color: SystemColors.volume,
                                value: Binding(get: { module.isMuted ? 0 : module.volume }, set: { module.setVolume($0) }))
                    Spacer(minLength: 8)
                    if module.brightness != nil {
                        LevelSlider(title: "Display", symbol: "sun.max.fill", color: SystemColors.display,
                                    value: Binding(get: { module.brightness ?? 0 }, set: { module.setBrightness($0) }))
                        Spacer(minLength: 8)
                    }
                    if module.keyboardBrightness != nil {
                        LevelSlider(title: "Keyboard", symbol: "light.max", color: SystemColors.keyboard,
                                    value: Binding(get: { module.keyboardBrightness ?? 0 },
                                                   set: { module.setKeyboardBrightness($0) }))
                    }
                    if module.needsAccessibility {
                        Spacer(minLength: 6)
                        Button("Allow Accessibility for the custom HUD") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(.island)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SystemColors.display)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                if module.battery.hasBattery {
                    BatteryCard(battery: module.battery)
                }
                KeepAwakeCard(module: module)
            }
            .frame(width: 236)
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .onAppear { module.refreshLevels() }
    }
}

private struct LevelSlider: View {
    let title: String
    let symbol: String
    let color: Color
    @Binding var value: Float

    var body: some View {
        let level = CGFloat(min(max(value, 0), 1))
        HStack(spacing: 10) {
            IconBadge(symbol, color: color, size: 24)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("\(Int((level * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(color)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(geo.size.width * level, 8))
                            .shadow(color: color.opacity(0.5), radius: 4)
                        Circle()
                            .fill(.white)
                            .frame(width: 12, height: 12)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: min(max(geo.size.width * level - 6, 0), geo.size.width - 12))
                    }
                    .frame(height: 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        value = Float(min(max(drag.location.x / geo.size.width, 0), 1))
                    })
                    .pointingHandCursor()
                }
                .frame(height: 14)
            }
        }
        .animation(.easeOut(duration: 0.1), value: value)
    }
}

private struct BatteryCard: View {
    let battery: BatteryMonitor

    var body: some View {
        let color = battery.isCharging || battery.percent > 20 ? SystemColors.battery : SystemColors.lowBattery
        IslandCard(tint: color, padding: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(battery.percent) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.5), radius: 3)
                    Image(systemName: battery.isCharging ? "bolt.fill" : "battery.100")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(battery.percent)%")
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var detail: String {
        if let minutes = battery.timeRemaining {
            return battery.isCharging ? "Full in \(Self.format(minutes))" : "\(Self.format(minutes)) left"
        }
        if battery.isCharging { return "Charging" }
        return battery.isPluggedIn ? "Plugged in" : "On battery"
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
            Toggle("Replace the volume, brightness & keyboard light HUD", isOn: $module.replaceHUD)
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

private struct KeepAwakeCard: View {
    let module: SystemModule

    private static let options: [(label: String, minutes: Int?)] = [("30m", 30), ("1h", 60), ("2h", 120), ("∞", nil)]

    var body: some View {
        let hold = module.manualAwake
        let color = SystemColors.awake
        IslandCard(tint: color, padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconBadge("cup.and.saucer.fill", color: color, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep awake")
                            .font(.system(size: 11, weight: .semibold))
                        Group {
                            if let until = hold?.until {
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text("\(AwakeFormat.remaining(until.timeIntervalSince(context.date))) left")
                                }
                            } else {
                                Text(hold != nil ? "Until turned off" : "Off")
                            }
                        }
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    if hold != nil {
                        Button { module.stopKeepAwake() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.island)
                        .help("Stop keeping awake")
                    }
                }
                HStack(spacing: 5) {
                    ForEach(Self.options, id: \.label) { option in
                        let selected = hold != nil && optionMatches(option.minutes, hold)
                        Button { module.keepAwake(minutes: option.minutes) } label: {
                            Text(option.label)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .foregroundStyle(selected ? .white : .white.opacity(0.8))
                                .background(selected ? color.opacity(0.55) : .white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.island)
                    }
                }
            }
        }
    }

    private func optionMatches(_ minutes: Int?, _ hold: KeepAwake.Hold?) -> Bool {
        minutes == nil ? hold?.until == nil : false
    }
}
