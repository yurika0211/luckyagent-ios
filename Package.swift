// swift-tools-version: 5.9
import PackageDescription

// Protocol, state and Markdown rendering tests run on macOS without an iOS simulator.
// The application itself is built from project.yml with XcodeGen.
let package = Package(
    name: "LuckyAgentCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "LuckyAgent", targets: ["LuckyAgent"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1")
    ],
    targets: [
        .target(
            name: "LuckyAgent",
            dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources",
            exclude: ["ChatView.swift", "LuckyAgentApp.swift", "RuntimeViews.swift", "Info.plist"],
            sources: ["Models.swift", "APIClient.swift", "OutboundQueue.swift", "SocketClient.swift", "SettingsStore.swift", "AppModel.swift", "RuntimePresentation.swift", "ChatMarkdownView.swift", "Theme.swift"]
        ),
        .testTarget(name: "LuckyAgentTests", dependencies: ["LuckyAgent"], path: "Tests")
    ]
)
