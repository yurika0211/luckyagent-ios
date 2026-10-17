// swift-tools-version: 5.9
import PackageDescription

// Core protocol/state tests run on macOS without an installed iOS simulator.
// The application itself is built from project.yml with XcodeGen.
let package = Package(
    name: "LuckyAgentCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "LuckyAgent", targets: ["LuckyAgent"])],
    targets: [
        .target(
            name: "LuckyAgent",
            path: "Sources",
            exclude: ["ChatView.swift", "LuckyAgentApp.swift", "RuntimeViews.swift", "Theme.swift", "Info.plist"],
            sources: ["Models.swift", "APIClient.swift", "OutboundQueue.swift", "SocketClient.swift", "SettingsStore.swift", "AppModel.swift", "RuntimePresentation.swift"]
        ),
        .testTarget(name: "LuckyAgentTests", dependencies: ["LuckyAgent"], path: "Tests")
    ]
)
