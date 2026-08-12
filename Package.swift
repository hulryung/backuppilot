// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupPilot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BackupPilot",
            path: "Sources/BackupPilot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
