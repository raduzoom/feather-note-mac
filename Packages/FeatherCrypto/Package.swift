// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherCrypto",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherCrypto", targets: ["FeatherCrypto"]),
    ],
    dependencies: [
        // libsodium as a prebuilt xcframework; FeatherCrypto calls its C API directly (Sodium.swift)
        .package(url: "https://github.com/jedisct1/swift-sodium", exact: "0.9.1"),
        .package(path: "../FeatherCore"),
    ],
    targets: [
        .target(name: "FeatherCrypto", dependencies: [
            .product(name: "Clibsodium", package: "swift-sodium"),
            "FeatherCore",
        ]),
        .testTarget(name: "FeatherCryptoTests", dependencies: ["FeatherCrypto", "FeatherCore"]),
    ]
)
