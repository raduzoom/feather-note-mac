// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatherImport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FeatherImport", targets: ["FeatherImport"]),
    ],
    dependencies: [
        .package(path: "../FeatherCore"),
    ],
    targets: [
        .target(name: "FeatherImport", dependencies: ["FeatherCore"]),
        .testTarget(name: "FeatherImportTests", dependencies: ["FeatherImport", "FeatherCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
