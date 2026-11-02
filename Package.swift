// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FilterAssets",
    products: [
        .library(
            name: "FilterAssets",
            targets: ["FilterAssets"]
        )
    ],
    targets: [
        .target(
            name: "FilterAssets",
            resources: [.process("Resources")]
        )
    ]
)
