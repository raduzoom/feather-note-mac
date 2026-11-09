// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherCrypto",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherCrypto", targets: ["FeatherCrypto"]),
    ],
    targets: [
        .target(name: "FeatherCrypto"),
        .testTarget(name: "FeatherCryptoTests", dependencies: ["FeatherCrypto"]),
    ]
)
