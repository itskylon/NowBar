// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentMeter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentMeter", targets: ["AgentMeter"])],
    targets: [
        .target(name: "AgentMeterCore"),
        .executableTarget(name: "AgentMeter", dependencies: ["AgentMeterCore"]),
        .testTarget(name: "AgentMeterCoreTests", dependencies: ["AgentMeterCore"])
    ]
)
