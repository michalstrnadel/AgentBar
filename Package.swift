// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "AgentBar", path: "Sources/AgentBar")
    ]
)
