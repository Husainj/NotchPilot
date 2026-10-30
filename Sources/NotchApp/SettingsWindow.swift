import AppKit
import NotchShell
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let registry: ModuleRegistry
    private let updater: Updater
    private var window: NSWindow?

    init(registry: ModuleRegistry, updater: Updater) {
        self.registry = registry
        self.updater = updater
    }

    func show() {
        if window == nil {
            let root = SettingsView(registry: registry, updater: updater)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "\(AppInfo.name) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 580))
            window.setFrameAutosaveName("SettingsWindow")
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private enum SettingsPane: Hashable {
    case general, modules, about
    case module(String)
}

/// A sidebar of panes, like System Settings, so every module's settings
/// stay reachable however many modules there are.
private struct SettingsView: View {
    let registry: ModuleRegistry
    let updater: Updater
    @State private var selection: SettingsPane? = .general

    private var configurable: [any NotchModule] {
        registry.all.filter { $0.makeSettingsView() != nil }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("General", systemImage: "gearshape").tag(SettingsPane.general)
                    Label("Modules", systemImage: "square.grid.2x2").tag(SettingsPane.modules)
                }
                Section("Modules") {
                    ForEach(configurable, id: \.id) { module in
                        Label(module.title, systemImage: module.systemImage)
                            .foregroundStyle(registry.isEnabled(module.id) ? .primary : .secondary)
                            .tag(SettingsPane.module(module.id))
                    }
                }
                Section {
                    Label("About", systemImage: "info.circle").tag(SettingsPane.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
        }
        .frame(minWidth: 720, minHeight: 500)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettings()
        case .modules:
            ModulesSettings(registry: registry)
        case .about:
            AboutSettings(updater: updater)
        case let .module(id):
            if let module = registry.all.first(where: { $0.id == id }), let view = module.makeSettingsView() {
                VStack(spacing: 0) {
                    if !registry.isEnabled(id) {
                        DisabledBanner { registry.setEnabled(id, true) }
                    }
                    view
                }
                .id(id)
            }
        }
    }

    private var title: String {
        switch selection ?? .general {
        case .general: "General"
        case .modules: "Modules"
        case .about: "About"
        case let .module(id): registry.all.first { $0.id == id }?.title ?? ""
        }
    }
}

private struct DisabledBanner: View {
    let enable: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "eye.slash")
            Text("This module is turned off, so it isn't in the island.")
            Spacer()
            Button("Turn On", action: enable)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.15))
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = NotchSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch \(AppInfo.name) at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = "Couldn't change login item: \(error.localizedDescription). Move \(AppInfo.name) to the Applications folder and try again."
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Picker("Show island on", selection: $settings.display) {
                ForEach(DisplayChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Hide in full-screen apps", isOn: $settings.hideInFullScreen)
            LabeledContent("Toggle island shortcut") {
                HotKeyRecorder(combo: $settings.toggleHotKey)
            }

            Section("Opening") {
                Picker("Open the island on", selection: $settings.openMode) {
                    ForEach(OpenMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.openMode == .hover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $settings.hoverOpenDelay, in: 0...1, step: 0.05)
                                .frame(width: 160)
                            Text(String(format: "%.2fs", settings.hoverOpenDelay))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Toggle("Haptic feedback when opening", isOn: $settings.haptics)
            }

            Section("Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme")
                    ThemePicker(theme: $settings.theme)
                }
                Toggle("Show live activities beside the notch", isOn: $settings.showLiveActivities)
                Picker("When nothing is live, show", selection: $settings.idleDisplay) {
                    ForEach(IdleDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.idleDisplay == .customText {
                    TextField("Text", text: $settings.idleCustomText, prompt: Text("e.g. Ship it 🚀"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModulesSettings: View {
    let registry: ModuleRegistry

    var body: some View {
        Form {
            Section {
                ForEach(registry.all, id: \.id) { module in
                    Toggle(isOn: Binding(get: { registry.isEnabled(module.id) },
                                         set: { registry.setEnabled(module.id, $0) })) {
                        Label(module.title, systemImage: module.systemImage)
                    }
                }
            } footer: {
                Text("Disabled modules are hidden from the island and stop running in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    @Bindable var updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppInfo.name).font(.title2.weight(.semibold))
                        Text("Version \(updater.version)").foregroundStyle(.secondary)
                        Text("Free and open source, made by @\(AppInfo.author)")
                            .font(.callout)
                    }
                }
                HStack {
                    Button("Follow @\(AppInfo.author) on X") { NSWorkspace.shared.open(AppInfo.twitter) }
                    Button("Star on GitHub") { NSWorkspace.shared.open(AppInfo.githubRepo) }
                    Button("Website") { NSWorkspace.shared.open(AppInfo.website) }
                    Button("Report an Issue") { NSWorkspace.shared.open(AppInfo.issues) }
                }
            }
            Section("Updates") {
                if updater.isConfigured {
                    Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                }
                HStack {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                    Button("What's New") { NSWorkspace.shared.open(AppInfo.releaseNotes(for: AppInfo.version)) }
                }
            }
            Section("License") {
                Text("\(AppInfo.name) is released under the MIT License. Includes mediaremote-adapter, © 2025 Jonas van den Berg and contributors, BSD 3-Clause License. Includes Sparkle, © Sparkle Project contributors, MIT License.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
