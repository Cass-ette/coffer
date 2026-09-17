// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "coffer-cli",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "coffer-cli", targets: ["coffer-cli"])
    ],
    dependencies: [
        .package(path: "../CofferCore")
    ],
    targets: [
        .executableTarget(
            name: "coffer-cli",
            dependencies: ["CofferCore"],
            path: "Sources/coffer-cli"
        )
    ]
)
