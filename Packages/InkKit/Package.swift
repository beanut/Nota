// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InkKit",
    platforms: [.iOS("17.5")],
    products: [
        .library(name: "InkKit", targets: ["InkKit"]),
    ],
    targets: [
        .target(name: "InkKit"),
        .testTarget(name: "InkKitTests", dependencies: ["InkKit"]),
    ]
)
