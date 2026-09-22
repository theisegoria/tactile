// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TactileDemo",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "TactileDemo",
            dependencies: [.product(name: "Tactile", package: "DualSense Adaptor")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
