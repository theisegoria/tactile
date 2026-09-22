// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TactileDemo",
    platforms: [.macOS(.v15)],
    // The explicit name keeps the product lookup independent of the checkout
    // directory's name (SwiftPM derives a path dependency's identity from the
    // last path component, e.g. "DualSense-Adaptor" on CI). It must match the
    // root manifest's `name:`.
    dependencies: [.package(name: "Tactile", path: "../..")],
    targets: [
        .executableTarget(
            name: "TactileDemo",
            dependencies: [.product(name: "Tactile", package: "Tactile")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
