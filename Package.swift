// swift-tools-version:5.9
import PackageDescription

// Bounding-box annotator for Apple Create ML object-detection datasets.
//
//   swift run labelkit <path>     # dev
//   swift build -c release       # release binary at .build/release/labelkit
//   swift test                   # headless library tests
let package = Package(
    name: "labelkit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LabelKit", targets: ["LabelKit"]),
        .executable(name: "labelkit", targets: ["LabelKitApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0")
    ],
    targets: [
        // Everything testable headless: format IO, store, geometry, imaging.
        // No AppKit/SwiftUI imports allowed in this target.
        .target(name: "LabelKit"),
        // Thin shell: CLI parsing + SwiftUI app + views. Directory is named
        // LabelKitApp (not "labelkit") because APFS is case-insensitive —
        // the product below still names the binary `labelkit`.
        .executableTarget(
            name: "LabelKitApp",
            dependencies: [
                "LabelKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "LabelKitTests", dependencies: ["LabelKit"]),
    ]
)
