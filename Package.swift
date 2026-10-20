// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReckonNative",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Reckon", targets: ["ReckonApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "ReckonCore"),
        .executableTarget(name: "ReckonApp", dependencies: ["ReckonCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "ReckonChecks", dependencies: ["ReckonCore"], path: "Tests/ReckonCoreTests")
    ]
)
