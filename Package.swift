// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicNotch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The menu bar icon, Settings window, and build and release scripts shared by every app
        // made from AppShell. Package.resolved pins the exact commit; `swift package update`
        // moves to AppShell's latest.
        .package(url: "https://github.com/doom1337hvh/AppShell.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "MusicNotch",
            dependencies: ["AppShell"],
            path: "Sources/MusicNotch"
        )
    ]
)
