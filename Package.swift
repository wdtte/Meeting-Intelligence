// swift-tools-version: 6.2
import PackageDescription
import Foundation

let edition = ProcessInfo.processInfo.environment["MEETING_BUILD_EDITION"] ?? "standard"
guard ["standard", "compatibility"].contains(edition) else {
    fatalError("MEETING_BUILD_EDITION must be standard or compatibility")
}
let compatibility = edition == "compatibility"
let speechSettings: [SwiftSetting] = compatibility ? [.define("MEETING_WHISPER")] : []

let package = Package(
    name: "MeetingIntelligence",
    platforms: [.macOS(compatibility ? "15.0" : "26.0")],
    products: [
        .executable(name: "MeetingIntelligence", targets: ["MeetingIntelligence"]),
        .executable(name: "meeting", targets: ["MeetingCLI"])
    ],
    targets: [
        .target(name: "RealtimeAudio", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
        .target(name: "MeetingCore", dependencies: ["RealtimeAudio"], resources: [.process("Resources")], swiftSettings: speechSettings),
        .executableTarget(name: "MeetingIntelligence", dependencies: ["MeetingCore"]),
        .executableTarget(name: "MeetingCLI", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore", "RealtimeAudio"], swiftSettings: speechSettings),
        .testTarget(name: "MeetingCLITests", dependencies: ["MeetingCLI", "MeetingCore"]),
        .testTarget(name: "MeetingIntelligenceTests", dependencies: ["MeetingIntelligence", "MeetingCore"])
    ]
)
