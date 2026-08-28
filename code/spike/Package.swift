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
        ),
        // statusline 透传 wrapper：随 .app 分发的独立小二进制，不依赖 jq / python
        .executableTarget(
            name: "LdStatusline",
            path: "Sources/LdStatusline",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        // Notification hook 只读监听器：抽 permission_prompt / elicitation 写盘，随 .app 分发（决策 009）
        .executableTarget(
            name: "LdHook",
            path: "Sources/LdHook",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)