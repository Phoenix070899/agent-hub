// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HubApp",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
    ],
    targets: [
        .target(name: "HubCore", path: "Sources/HubCore"),
        .executableTarget(
            name: "HubApp",
            dependencies: [
                "HubCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            path: "Sources/HubApp"
        ),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"], path: "Tests/HubCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
