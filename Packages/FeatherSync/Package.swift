// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherSync",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherSync", targets: ["FeatherSync"]),
    ],
    dependencies: [
        .package(path: "../FeatherCore"),
        .package(path: "../FeatherCrypto"),
    ],
    targets: [
        .target(name: "FeatherSync", dependencies: ["FeatherCore", "FeatherCrypto"]),
        .testTarget(name: "FeatherSyncTests", dependencies: ["FeatherSync", "FeatherCore", "FeatherCrypto"]),
        // Needs the local server (see Harness.swift); not part of the app's scheme, so xcodebuild test needs no Docker.
        .testTarget(name: "FeatherSyncIntegrationTests", dependencies: ["FeatherSync", "FeatherCore", "FeatherCrypto"]),
    ]
)
