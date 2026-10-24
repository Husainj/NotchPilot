import AppKit
import NotchShell
import SwiftUI

/// Shown once on first launch.
struct WelcomeView: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to \(AppInfo.name)").font(.title2.weight(.semibold))
                    Text("Your notch, now useful. Free and open source.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Tip(symbol: "cursorarrow.motionlines", text: "Move the pointer to the notch to open the island.")
                Tip(symbol: "keyboard", text: "Press \(NotchSettings.shared.toggleHotKey?.displayString ?? "your shortcut") to open it from anywhere.")
                Tip(symbol: "sparkles", text: "Connect Claude Code, Codex or Cursor in Settings → AI to see your agents live.")
                Tip(symbol: "menubar.rectangle", text: "Settings, updates and Quit live in the menu bar icon.")
            }
            Divider()
            HStack {
                Button("Follow @\(AppInfo.author) on X") { NSWorkspace.shared.open(AppInfo.twitter) }
                Button("Star on GitHub") { NSWorkspace.shared.open(AppInfo.githubRepo) }
                Spacer()
                Button("Open Settings") {
                    NSApp.keyWindow?.close()
                    openSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Shown once after an update.
struct WhatsNewView: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Updated to \(version)").font(.title3.weight(.semibold))
            Text("See what changed in this release, and follow @\(AppInfo.author) for what's coming next.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Follow on X") { NSWorkspace.shared.open(AppInfo.twitter) }
                Spacer()
                Button("Not Now") { NSApp.keyWindow?.close() }
                Button("See What's New") {
                    NSWorkspace.shared.open(AppInfo.releaseNotes(for: version))
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
