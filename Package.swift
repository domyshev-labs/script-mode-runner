// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ModeRunner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ModeRunner", targets: ["ModeRunnerApp"]),
        .library(name: "ModeRunnerCore", targets: ["ModeRunnerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.2"),
    ],
    targets: [
        .target(
            name: "ModeRunnerCore",
            dependencies: ["Yams"]
        ),
        .executableTarget(
            name: "ModeRunnerApp",
            dependencies: ["ModeRunnerCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ModeRunnerCoreTests",
            dependencies: ["ModeRunnerCore"]
        ),
        .testTarget(
            name: "ModeRunnerAppTests",
            dependencies: ["ModeRunnerApp"]
        ),
    ]
)
