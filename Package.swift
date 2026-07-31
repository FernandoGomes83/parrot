// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Pinned to the minor: FluidAudio is pre-1.0 and moves its ASR API
        // between minors, so allow patches only.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
