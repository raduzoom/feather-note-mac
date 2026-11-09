// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherImport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherImport", targets: ["FeatherImport"]),
    ],
    targets: [
        .target(name: "FeatherImport"),
        .testTarget(name: "FeatherImportTests", dependencies: ["FeatherImport"]),
    ]
)
