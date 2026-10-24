# Contributing

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Build and run

Requires macOS 14+ and Xcode 16+ (or the Command Line Tools with Swift 6).

```bash
make run    # debug build of the app in ./build, then launch it
make test   # unit tests (Swift Testing)
```

To work in Xcode, open `Package.swift` and run the `NotchApp` scheme. Run `make adapter` once first so Now Playing works. For anything that needs a real `.app` bundle (permissions, launch at login, Sparkle), use `make run`.

## How the code is organised

- `Sources/NotchShell` contains the island window, notch geometry, the hover/open state machine, settings, hotkeys and shared services (`KeepAwake`, `CallStatus`, `MeetingLink`, `AppInfo`).
- Each feature is a module in its own target (`Sources/Module*`). A module implements `NotchModule` (`Sources/NotchShell/NotchModule.swift`), with an expanded view, an optional settings view, an optional header accessory and an optional live activity beside the notch.
- Modules are registered in `Sources/NotchApp/AppDelegate.swift`, in the order the tabs appear.

To add a module:
1. Create `Sources/ModuleYourThing/` and add the target, plus a test target, to `Package.swift`.
2. Implement `NotchModule` as an `@Observable @MainActor` class.
3. Register it in `AppDelegate`. Pass `enabledByDefault: false` if it's niche or needs a scary permission.

## Guidelines

- **Swift 6 strict concurrency.** The build must stay warning-free.
- **Battery first.** Don't poll in the background unless you must, and only sample while a tab is visible (see `StatsSampler`, `AIModule.viewAppeared`).
- **Privacy.** Nothing leaves the Mac unless a feature obviously needs the network (weather). No analytics.
- **Permissions.** Ask only when the user opens the feature that needs one, and explain why in `Info.plist`.
- **Tests.** Put logic in plain types (parsers, state machines) so it can be unit-tested; see `SessionBoard`, `CallTracker` and `UsageBlock`.
- **Style.** Match the surrounding code and keep comments for *why*, not *what*.

## Pull requests

- Keep each PR focused on one change. For UI changes, include a screenshot or GIF.
- Run `make test` and `make app` before pushing; CI runs both.
- Explain how you tested it and on which Mac and macOS version.
