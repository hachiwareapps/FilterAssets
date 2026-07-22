// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FilterAssetsReproducer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "filter-assets-reproducer", targets: ["Reproducer"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/hachiwareapps/BlockerKitSDK.git",
            exact: "0.12.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "Reproducer",
            dependencies: [.product(name: "BlockerKit", package: "BlockerKitSDK")]
        ),
        .testTarget(
            name: "ReproducerTests",
            dependencies: [
                "Reproducer",
                .product(name: "BlockerKit", package: "BlockerKitSDK")
            ]
        )
    ]
)
