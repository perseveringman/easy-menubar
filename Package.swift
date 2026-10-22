// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Bar",
            path: "Sources/Bar",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "BarTests", dependencies: ["Bar"])
    ]
)
