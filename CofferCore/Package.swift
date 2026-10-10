// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CofferCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CofferCore", targets: ["CofferCore"])],
    dependencies: [.package(path: "../Vendor/TronKit")],
    targets: [
        .target(
            name: "CofferCore",
            dependencies: ["TronKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CofferCoreTests",
            dependencies: ["CofferCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
