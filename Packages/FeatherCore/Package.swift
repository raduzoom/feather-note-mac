// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherCore", targets: ["FeatherCore"]),
    ],
    targets: [
        .target(name: "FeatherCore"),
        .testTarget(name: "FeatherCoreTests", dependencies: ["FeatherCore"]),
    ]
)
