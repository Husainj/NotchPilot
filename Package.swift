// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchPilot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "NotchApp",
            dependencies: [
                "NotchShell",
                "ModuleMedia", "ModuleSystem", "ModuleShelf", "ModuleClipboard",
                "ModuleTimers", "ModuleNotes", "ModuleStats", "ModuleCalendar", "ModuleWeather", "ModuleMirror", "ModuleAI", "ModuleMeeting",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // Sparkle.framework is copied into NotchPilot.app/Contents/Frameworks by scripts/bundle.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(name: "NotchShell"),
        .target(name: "ModuleMedia", dependencies: ["NotchShell"]),
        .target(name: "ModuleSystem", dependencies: ["NotchShell"]),
        .target(name: "ModuleShelf", dependencies: ["NotchShell"]),
        .target(name: "ModuleClipboard", dependencies: ["NotchShell"]),
        .target(name: "ModuleTimers", dependencies: ["NotchShell"]),
        .target(name: "ModuleNotes", dependencies: ["NotchShell"]),
        .target(name: "ModuleStats", dependencies: ["NotchShell"]),
        .target(name: "ModuleCalendar", dependencies: ["NotchShell"]),
        .target(name: "ModuleWeather", dependencies: ["NotchShell"]),
        .target(name: "ModuleMirror", dependencies: ["NotchShell"]),
        .target(name: "ModuleAI", dependencies: ["NotchShell"]),
        .target(name: "ModuleMeeting", dependencies: ["NotchShell"]),
        .testTarget(name: "NotchShellTests", dependencies: ["NotchShell"]),
        .testTarget(name: "ModuleClipboardTests", dependencies: ["ModuleClipboard"]),
        .testTarget(name: "ModuleMediaTests", dependencies: ["ModuleMedia"]),
        .testTarget(name: "ModuleWeatherTests", dependencies: ["ModuleWeather"]),
        .testTarget(name: "ModuleStatsTests", dependencies: ["ModuleStats"]),
        .testTarget(name: "ModuleAITests", dependencies: ["ModuleAI"]),
        .testTarget(name: "ModuleMeetingTests", dependencies: ["ModuleMeeting", "NotchShell"]),
    ]
)
