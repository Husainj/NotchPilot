# NotchPilot

**A free, open-source Dynamic Island for your Mac, with a live dashboard for your AI coding agents.**

<!-- Add a hero GIF here: ![NotchPilot demo](docs/demo.gif) -->

[Download](https://github.com/Husainj/notchpilot/releases/latest) · [Website](https://notchpilot.husainjhalod.me/) · [Follow @husain_j53 on X](https://x.com/husain_j53)

## Features

- **AI coding control center**
  - Live Claude Code, Codex and Cursor sessions: working, needs your approval, done or failed. Alerts appear on the notch, and clicking a session jumps to its terminal.
  - Usage and API-equivalent cost per day and model.
  - A countdown to your Claude 5-hour limit reset, plus Codex's real limit percentages.
- **Meeting mode**
  - Mute your mic in every app with one shortcut (⌃⌥M).
  - A live mic/camera indicator that shows which app is listening.
  - Call detection with a call timer, and automatic unmute after the call.
  - One-click **Join** for Zoom, Meet and Teams events.
- **Screen Time with a nudge**
  - Tracks time per app and per website (domain only), with a focus score, daily streak and weekly chart.
  - After 30 minutes of Instagram, YouTube, X, Reddit and similar, Pilot the mascot drops down from the notch with a check-in and your Reminders tasks: Back to work, 5 more min, or Taking a break. It gets firmer if you keep going, but never blocks anything.
- **Keep awake**
  - Stops idle sleep while an AI agent is working, then lets the Mac sleep normally.
  - Manual 30m / 1h / 2h / ∞, with battery and time limits.
- **Now Playing** for any app (Spotify, Music, browsers, local files), with artwork and controls.
- **File Shelf**: drop files on the notch, then drag them out, AirDrop them or Quick Look them.
- **Clipboard history** with search and pinning. It skips password managers.
- **Timers and Pomodoro**, **Notes**, **Calendar and Reminders**, **Weather**, **System Stats**, a **volume/brightness HUD**, battery details and a **camera Mirror**.
- Themes, hover or click to open, and an always-on clock/date/text on the closed notch. Macs without a notch get a pill at the top of the screen.

**Private by design.** Nothing leaves your Mac except weather requests (MET Norway) and update checks (GitHub). There's no account, analytics or tracking.

## Install

**Download:** grab the `.dmg` from [Releases](https://github.com/Husainj/notchpilot/releases/latest) and drag the app to Applications.

**Homebrew:**
```bash
brew install --cask husainj/tap/notchpilot
```

**First launch:** the app isn't notarized by Apple yet, so macOS blocks it the first time.
1. Open the app and click **Done** on the warning.
2. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

You only do this once; updates install automatically. ([Illustrated guide](https://notchpilot.husainjhalod.me/install.html))

### Permissions (all optional, asked only when you use the feature)
| Permission | Used for |
|---|---|
| Accessibility | Replacing the volume/brightness HUD |
| Automation (Music/Spotify, browsers) | Reading the current track; reading the current website's domain for Screen Time |
| Calendars, Reminders | Agenda, reminders, meeting Join buttons |
| Location | Local weather (or type a city instead) |
| Camera | The Mirror tab (off by default) |

Meeting mode needs no microphone permission. It reads the mic's on/off state and mutes it, but never records.

## Build from source

Requires macOS 14+ and Xcode 16+ (or the Command Line Tools with Swift 6).

```bash
git clone https://github.com/Husainj/notchpilot && cd notchpilot
make run      # debug build in ./build, then launch it
make test     # unit tests
make install  # release build copied to /Applications
```

To work in Xcode, open `Package.swift` and run the `NotchApp` scheme. Run `make adapter` once first so Now Playing works. Anything involving permissions, launch at login or Sparkle needs `make run`, because those need a real `.app` bundle.

### Layout
```
Sources/
├─ NotchApp         app entry, menu bar, Settings, welcome / what's new, Sparkle updater
├─ NotchShell       island panel, notch geometry, open/close state machine, module host, hotkeys,
│                   shared services (AppInfo, KeepAwake, CallStatus, MeetingLink)
├─ ModuleAI         coding-agent sessions (hooks → ~/.notch/notch-agent-hook → AgentEvents/), usage from ~/.claude + ~/.codex
├─ ModuleScreenTime app/site usage, doomscroll nudge with the Pilot mascot
├─ ModuleMeeting    mic/camera in use (CoreAudio/CoreMediaIO), system-wide mute, call detection, Join links
├─ ModuleMedia      now playing for any app (via Vendor/mediaremote-adapter) + controls
├─ ModuleSystem     volume/brightness HUD, battery, keep-awake controls
├─ ModuleShelf · ModuleClipboard · ModuleTimers · ModuleNotes · ModuleCalendar · ModuleWeather · ModuleStats · ModuleMirror
scripts/            bundle.sh, release.sh, sparkle-keys.sh, homebrew-cask.rb.template, make-icon.swift
docs/               website + appcast.xml, served by GitHub Pages
```

Adding a feature means implementing `NotchModule` (`Sources/NotchShell/NotchModule.swift`) and registering it in `AppDelegate`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Releasing (maintainers)

All free: GitHub Releases host the DMGs, GitHub Pages hosts the update feed, and GitHub Actions builds releases.

**One-time setup**
1. **Repo:** create the public repo `Husainj/notchpilot` and push `main`. The update feed (`SUFeedURL` in `Resources/Info.plist`) is already `https://notchpilot.husainjhalod.me/appcast.xml`.
2. **GitHub Pages:** in **Settings → Pages**, choose "Deploy from a branch", branch `main`, folder `/docs`. The site uses the custom domain in `docs/CNAME` (`notchpilot.husainjhalod.me`), which needs a DNS **CNAME** record `notchpilot` → `husainj.github.io`. Turn on **Enforce HTTPS** once the certificate is ready.
3. **Signing key:** run `make sparkle-keys`. It writes the public key into Info.plist and creates the private signing key.
   - **Back up the private key.** Lose it and existing users can never auto-update again.
   - Add it as the `SPARKLE_PRIVATE_KEY` repository secret for CI; the script prints the command.
4. **Homebrew tap:** create the repo `Husainj/homebrew-tap` and copy `scripts/homebrew-cask.rb.template` to `Casks/notchpilot.rb` in it.

**Each release**
1. Write `release-notes/1.2.0.md`. The first run creates a template.
2. Release, either way:
   - **Locally:** `make release VERSION=1.2.0`. It builds and signs, tags `v1.2.0`, uploads the DMG to GitHub Releases, then updates and pushes `docs/appcast.xml`. Use `PUBLISH=0` to build without pushing anything.
   - **In CI:** **Actions → Release → Run workflow** with the version.
3. Update `version` and `sha256` in the Homebrew cask; the release output prints both.

Users get the update within 24 hours.

**Later, with an Apple Developer ID ($99/yr):** set `SIGN_IDENTITY="Developer ID Application: …"` and `NOTARY_PROFILE=…` for `make release`. That removes the "Open Anyway" step, keeps permissions across updates, and makes the app eligible for the official Homebrew cask.

### Renaming
- **In Swift:** change `AppInfo.name` and the links in `Sources/NotchShell/AppInfo.swift`.
- **In `Resources/Info.plist`:** change `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable` and `CFBundleIdentifier`.
- **Elsewhere:** the scripts read the name from Info.plist. Update the website (`docs/`), the cask template and this README.
- **Leave as is:** the `~/.notch` hook folder and `~/Library/Application Support/Notch`. Connected coding agents and saved data point at them.

## Contributing

Issues and PRs are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and report security problems privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Includes [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause) and [Sparkle](https://sparkle-project.org) (MIT).

---

Made by [@husain_j53](https://x.com/husain_j53). If it's useful to you, a ⭐ on GitHub and a follow help a lot.
