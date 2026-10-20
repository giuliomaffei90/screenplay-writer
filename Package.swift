// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScreenplayWriter",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenplayWriter",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "ScreenplayWriterTests",
            dependencies: ["ScreenplayWriter"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
