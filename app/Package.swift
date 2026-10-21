// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// libghostty, built into Vendor/GhosttyKit by `Ghostty/build.sh` (the Makefile runs it).
let ghostty = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/GhosttyKit").path

let package = Package(
    name: "HubApp",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
    ],
    targets: [
        .target(name: "HubCore", path: "Sources/HubCore"),
        .systemLibrary(name: "GhosttyKit", path: "Vendor/GhosttyKit/include"),
        .executableTarget(
            name: "HubApp",
            dependencies: [
                "HubCore",
                "GhosttyKit",
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            path: "Sources/HubApp",
            linkerSettings: [
                .unsafeFlags(["-L", ghostty + "/lib"]),
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"], path: "Tests/HubCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
