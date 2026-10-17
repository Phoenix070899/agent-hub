// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HubApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "HubCore", path: "Sources/HubCore"),
        .executableTarget(
            name: "HubApp",
            dependencies: ["HubCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/HubApp"
        ),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"], path: "Tests/HubCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
