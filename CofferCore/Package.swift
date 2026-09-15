// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CofferCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CofferCore", targets: ["CofferCore"])],
    targets: [
        .target(
            name: "CofferCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CofferCoreTests",
            dependencies: ["CofferCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
