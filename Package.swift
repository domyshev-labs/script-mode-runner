// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScriptModeRunner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScriptModeRunner", targets: ["ScriptModeRunnerApp"]),
        .library(name: "ScriptModeRunnerCore", targets: ["ScriptModeRunnerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.2"),
    ],
    targets: [
        .target(
            name: "ScriptModeRunnerCore",
            dependencies: ["Yams"]
        ),
        .executableTarget(
            name: "ScriptModeRunnerApp",
            dependencies: ["ScriptModeRunnerCore"]
        ),
        .testTarget(
            name: "ScriptModeRunnerCoreTests",
            dependencies: ["ScriptModeRunnerCore"]
        ),
        .testTarget(
            name: "ScriptModeRunnerAppTests",
            dependencies: ["ScriptModeRunnerApp"]
        ),
    ]
)
