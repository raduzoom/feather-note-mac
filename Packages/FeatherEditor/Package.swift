// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherEditor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherEditor", targets: ["FeatherEditor"]),
    ],
    targets: [
        .target(name: "FeatherEditor"),
        .testTarget(name: "FeatherEditorTests", dependencies: ["FeatherEditor"]),
    ]
)
