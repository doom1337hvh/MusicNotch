// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MusicNotch",
            path: "Sources/MusicNotch"
        )
    ]
)
