// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FixtureCore",
    products: [
        .library(name: "FixtureCore", targets: ["FixtureCore"])
    ],
    targets: [
        .target(name: "FixtureCore"),
        .testTarget(name: "FixtureCoreTests", dependencies: ["FixtureCore"])
    ]
)
