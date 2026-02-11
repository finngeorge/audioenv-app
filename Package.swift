// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioEnv",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AudioEnv",
            path: "Sources/AudioEnv",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
