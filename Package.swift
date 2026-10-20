// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReckonNative",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Reckon", targets: ["ReckonApp"])],
    targets: [
        .target(name: "ReckonCore"),
        .executableTarget(name: "ReckonApp", dependencies: ["ReckonCore"]),
        .executableTarget(name: "ReckonChecks", dependencies: ["ReckonCore"], path: "Tests/ReckonCoreTests")
    ]
)
