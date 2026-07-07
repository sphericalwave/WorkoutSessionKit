// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkoutSessionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WorkoutSessionKit", targets: ["WorkoutSessionKit"]),
    ],
    targets: [
        .target(name: "WorkoutSessionKit"),
        .testTarget(name: "WorkoutSessionKitTests", dependencies: ["WorkoutSessionKit"]),
    ]
)
