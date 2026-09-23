// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Tactile",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TactileCore", targets: ["TactileCore"]),
        .library(name: "TactileTransport", targets: ["TactileTransport"]),
        .library(name: "TactileHaptics", targets: ["TactileHaptics"]),
        .library(name: "TactileBridge", targets: ["TactileBridge"]),
        .library(name: "Tactile", targets: ["Tactile"]),
        // EXPERIMENTAL (gate 6): speaker / mic audio research.
        .library(name: "TactileAudio", targets: ["TactileAudio"]),
        // C ABI for engines and non-Swift hosts. Header: Sources/CTactileHeaders/include/tactile.h
        .library(name: "CTactile", type: .dynamic, targets: ["TactileCABI"]),
        .executable(name: "tactilectl", targets: ["tactilectl"]),
        .executable(name: "tactile-probe", targets: ["tactile-probe"]),
    ],
    targets: [
        // Pure protocol logic. No I/O, no platform frameworks, no dependencies.
        .target(name: "TactileCore", swiftSettings: strict),
        .target(
            name: "TactileTransport",
            dependencies: ["TactileCore"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("CoreHID"), .linkedFramework("IOKit")]
        ),
        .target(
            name: "TactileHaptics",
            dependencies: ["TactileCore"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("AVFAudio")]
        ),
        .target(
            name: "TactileAudio",
            dependencies: ["TactileCore"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("AudioToolbox")]
        ),
        .target(
            name: "TactileBridge",
            dependencies: ["TactileCore", "TactileTransport"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("GameController")]
        ),
        // High-level facade: one Controller object tying transport, haptics and bridge together.
        .target(
            name: "Tactile",
            dependencies: ["TactileCore", "TactileTransport", "TactileHaptics", "TactileBridge", "TactileAudio"],
            swiftSettings: strict
        ),
        .target(name: "CTactileHeaders"),
        .target(name: "TactileCABI", dependencies: ["Tactile", "CTactileHeaders"], swiftSettings: strict),
        .executableTarget(name: "tactilectl", dependencies: ["Tactile"], swiftSettings: strict),
        .executableTarget(
            name: "tactile-probe",
            dependencies: ["TactileCore", "TactileTransport"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("GameController")]
        ),
        .testTarget(name: "TactileCoreTests", dependencies: ["TactileCore"], swiftSettings: strict),
        .testTarget(name: "TactileAudioTests", dependencies: ["TactileAudio", "TactileCore"], swiftSettings: strict),
        .testTarget(name: "TactileHapticsTests", dependencies: ["TactileHaptics", "TactileCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
