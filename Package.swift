// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentAssistant",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AgentAssistant", targets: ["AgentAssistant"])],
    targets: [.executableTarget(name: "AgentAssistant", path: "Sources")]
)
