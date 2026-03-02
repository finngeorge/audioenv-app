// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioEnv",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AudioEnv",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AudioEnv",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AudioEnvTests",
            dependencies: ["AudioEnv"],
            path: "Tests"
        )
    ]
)
