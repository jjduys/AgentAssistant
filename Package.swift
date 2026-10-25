// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TCenter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TCenter", targets: ["TCenter"])],
    targets: [.executableTarget(name: "TCenter", path: "Sources")]
)
