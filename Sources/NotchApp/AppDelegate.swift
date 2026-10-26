import AppKit
import ModuleAI
import ModuleCalendar
import ModuleClipboard
import ModuleMedia
import ModuleMeeting
import ModuleScreenTime
import ModuleMirror
import ModuleNotes
import ModuleShelf
import ModuleStats
import ModuleSystem
import ModuleTimers
import ModuleWeather
import NotchShell
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let registry = ModuleRegistry()
    private let updater = Updater()
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var infoWindow: NSWindow?
    private lazy var settingsWindow = SettingsWindowController(registry: registry, updater: updater)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tab order in the island.
        registry.register(MediaModule())
        registry.register(AIModule())
        registry.register(ShelfModule())
        registry.register(ClipboardModule())
        let calendar = CalendarModule()
        registry.register(MeetingModule(meetings: { calendar.upcomingMeetings }))
        registry.register(ScreenTimeModule(tasks: { calendar.focusTasks },
                                           completeTask: { calendar.completeTask($0) },
                                           nextMeeting: { calendar.upcomingMeetings.first },
                                           hasReminderAccess: { calendar.hasReminderAccess }))
        registry.register(TimersModule())
        registry.register(NotesModule())
        registry.register(calendar)
        registry.register(WeatherModule())
        registry.register(StatsModule())
        registry.register(SystemModule())
        registry.register(MirrorModule(), enabledByDefault: false)

        setUpStatusItem()
        updater.start()
        startIsland()
        NotchSettings.shared.onHotKeysChange = { [weak self] in self?.registerHotKeys() }
        showWelcomeOrWhatsNew()
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.stopAll()
    }

    private func startIsland() {
        guard notch == nil else { return }
        let notch = NotchWindowController(registry: registry)
        notch.show()
        self.notch = notch
        registerHotKeys()
    }

    private func registerHotKeys() {
        guard notch != nil else { return }
        HotKeyCenter.shared.register("toggle", combo: NotchSettings.shared.toggleHotKey) { [weak self] in
            self?.notch?.toggle()
        }
    }

    // MARK: - Welcome / What's new

    /// First launch shows a short welcome; after an update, a one-time "What's new".
    private func showWelcomeOrWhatsNew() {
        let defaults = UserDefaults.standard
        let current = AppInfo.version
        let lastSeen = defaults.string(forKey: "app.lastSeenVersion")
        defaults.set(current, forKey: "app.lastSeenVersion")
        if !defaults.bool(forKey: "app.didShowWelcome") {
            defaults.set(true, forKey: "app.didShowWelcome")
            showInfoWindow(WelcomeView(openSettings: { [weak self] in self?.openSettings() }), title: "Welcome to \(AppInfo.name)")
        } else if let lastSeen, lastSeen.compare(current, options: .numeric) == .orderedAscending {
            showInfoWindow(WhatsNewView(version: current), title: "\(AppInfo.name) was updated")
        }
    }

    private func showInfoWindow(_ view: some View, title: String) {
        infoWindow?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        infoWindow = window
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: AppInfo.name)
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Island", action: #selector(toggleIsland), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "What's New", action: #selector(openWhatsNew), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Star on GitHub…", action: #selector(openGitHub), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Follow @\(AppInfo.author) on X…", action: #selector(openTwitter), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func toggleIsland() { notch?.toggle() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func openWhatsNew() { NSWorkspace.shared.open(AppInfo.releaseNotes(for: AppInfo.version)) }
    @objc private func openGitHub() { NSWorkspace.shared.open(AppInfo.githubRepo) }
    @objc private func openTwitter() { NSWorkspace.shared.open(AppInfo.twitter) }
}
