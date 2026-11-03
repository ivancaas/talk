// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Talk",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2")
    ],
    targets: [
        .executableTarget(
            name: "Talk",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
