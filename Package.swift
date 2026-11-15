// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingIntelligence",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MeetingIntelligence", targets: ["MeetingIntelligence"]),
        .executable(name: "meeting", targets: ["MeetingCLI"])
    ],
    targets: [
        .target(name: "RealtimeAudio", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "MeetingCore", dependencies: ["RealtimeAudio"], resources: [.process("Resources")]),
        .executableTarget(name: "MeetingIntelligence", dependencies: ["MeetingCore"]),
        .executableTarget(name: "MeetingCLI", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore", "RealtimeAudio"]),
        .testTarget(name: "MeetingCLITests", dependencies: ["MeetingCLI", "MeetingCore"])
    ]
)
