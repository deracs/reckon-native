// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReckonNative",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Reckon", targets: ["ReckonApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "ReckonCore"),
        .target(name: "ReckonImages"),
        .executableTarget(name: "ReckonApp", dependencies: ["ReckonCore", "ReckonImages", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "ReckonImageChecks", dependencies: ["ReckonImages"], path: "Tests/ReckonImageTests"),
        .executableTarget(name: "ReckonChecks", dependencies: ["ReckonCore"], path: "Tests/ReckonCoreTests")
    ]
)
