// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherSync",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherSync", targets: ["FeatherSync"]),
    ],
    targets: [
        .target(name: "FeatherSync"),
        .testTarget(name: "FeatherSyncTests", dependencies: ["FeatherSync"]),
    ]
)
