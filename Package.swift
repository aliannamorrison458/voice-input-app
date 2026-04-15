// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            dependencies: ["VoiceInputCore"],
            path: "Sources/App",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .target(
            name: "VoiceInputCore",
            path: "Sources/Core"
        ),
        .testTarget(
            name: "VoiceInputTests",
            dependencies: ["VoiceInputCore"],
            path: "Tests"
        ),
    ]
)
