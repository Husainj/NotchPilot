import Foundation
import Observation

public enum DisplayChoice: String, CaseIterable, Sendable {
    case builtIn, main

    public var title: String {
        switch self {
        case .builtIn: "Built-in display"
        case .main: "Main display"
        }
    }
}

/// Shell-level preferences, persisted in UserDefaults.
@MainActor
@Observable
public final class NotchSettings {
    public static let shared = NotchSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    public var hoverOpenDelay: Double {
        didSet { defaults.set(hoverOpenDelay, forKey: "hoverOpenDelay") }
    }
    public var hideInFullScreen: Bool {
        didSet { defaults.set(hideInFullScreen, forKey: "hideInFullScreen") }
    }
    public var display: DisplayChoice {
        didSet { defaults.set(display.rawValue, forKey: "display"); onDisplayChange?() }
    }
    public var openMode: OpenMode {
        didSet { defaults.set(openMode.rawValue, forKey: "openMode") }
    }
    public var haptics: Bool {
        didSet { defaults.set(haptics, forKey: "haptics") }
    }
    public var theme: NotchTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    /// Module live activities (music, timers, charging) beside the closed notch.
    public var showLiveActivities: Bool {
        didSet { defaults.set(showLiveActivities, forKey: "showLiveActivities") }
    }
    public var idleDisplay: IdleDisplay {
        didSet { defaults.set(idleDisplay.rawValue, forKey: "idleDisplay") }
    }
    public var idleCustomText: String {
        didSet { defaults.set(idleCustomText, forKey: "idleCustomText") }
    }
    public var toggleHotKey: HotKeyCombo? {
        didSet { HotKeyCombo.store(toggleHotKey, key: "toggleHotKey", in: defaults); onHotKeysChange?() }
    }

    @ObservationIgnored public var onDisplayChange: (() -> Void)?
    @ObservationIgnored public var onHotKeysChange: (() -> Void)?

    private init() {
        defaults.register(defaults: ["hoverOpenDelay": 0.25, "hideInFullScreen": true, "haptics": true,
                                     "showLiveActivities": true])
        hoverOpenDelay = defaults.double(forKey: "hoverOpenDelay")
        hideInFullScreen = defaults.bool(forKey: "hideInFullScreen")
        display = DisplayChoice(rawValue: defaults.string(forKey: "display") ?? "") ?? .builtIn
        openMode = OpenMode(rawValue: defaults.string(forKey: "openMode") ?? "") ?? .hover
        haptics = defaults.bool(forKey: "haptics")
        theme = NotchTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .minimal
        showLiveActivities = defaults.bool(forKey: "showLiveActivities")
        idleDisplay = IdleDisplay(rawValue: defaults.string(forKey: "idleDisplay") ?? "") ?? .nothing
        idleCustomText = defaults.string(forKey: "idleCustomText") ?? ""
        toggleHotKey = defaults.object(forKey: "toggleHotKey") == nil
            ? .defaultToggle
            : HotKeyCombo.load(key: "toggleHotKey", from: defaults)
    }
}
