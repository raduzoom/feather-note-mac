// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherEditor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherEditor", targets: ["FeatherEditor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(name: "FeatherEditor", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .testTarget(name: "FeatherEditorTests", dependencies: ["FeatherEditor"], resources: [.copy("Fixtures")]),
    ]
)
