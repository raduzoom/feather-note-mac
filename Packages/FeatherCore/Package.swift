// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherCore", targets: ["FeatherCore"]),
        .executable(name: "fncore", targets: ["fncore"]),
    ],
    targets: [
        .target(name: "FeatherCore"),
        .executableTarget(name: "fncore", dependencies: ["FeatherCore"]),
        .testTarget(name: "FeatherCoreTests", dependencies: ["FeatherCore", "fncore"]),
    ]
)
