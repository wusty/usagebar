// swift-tools-version:5.9
import PackageDescription

// SPM here is used only to build & test the pure-logic library.
// The full menu bar app is built via `./build.sh` (direct swiftc), which
// also picks up `Sources/UsageBarLogic/ThresholdEvaluator.swift` so
// AppDelegate can call it directly without an `import` statement.
let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "UsageBarLogic",
            path: "Sources/UsageBarLogic"
        ),
        .testTarget(
            name: "UsageBarLogicTests",
            dependencies: ["UsageBarLogic"],
            path: "Tests/UsageBarLogicTests"
        )
    ]
)
