// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CofferCore",
    platforms: [.macOS(.v12)],
    products: [.library(name: "CofferCore", targets: ["CofferCore"])],
    dependencies: [
        .package(path: "../Vendor/TronKit"),
        .package(url: "https://github.com/horizontalsystems/HsCryptoKit.Swift.git", .upToNextMajor(from: "1.2.1")),
    ],
    targets: [
        .target(
            name: "CofferCore",
            dependencies: ["TronKit", .product(name: "HsCryptoKit", package: "HsCryptoKit.Swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CofferCoreTests",
            dependencies: ["CofferCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
