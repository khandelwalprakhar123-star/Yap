// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0")
    ],
    targets: [
        .target(
            name: "LocalFlowCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "localflow-cli",
            dependencies: ["LocalFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LocalFlowApp",
            dependencies: ["LocalFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
