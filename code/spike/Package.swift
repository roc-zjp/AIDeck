// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveDesktopSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LiveDesktopSpike",
            path: "Sources/LiveDesktopSpike",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
