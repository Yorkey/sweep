// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .executable(name: "SweepApp", targets: ["SweepApp"]),
    ],
    targets: [
        .target(name: "SweepCore"),
        .executableTarget(name: "SweepApp", dependencies: ["SweepCore"], exclude: ["Info.plist", "Sweep.entitlements"]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"]),
    ]
)
