// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InkKit",
    platforms: [.iOS("17.5")],
    products: [
        .library(name: "InkKit", targets: ["InkKit"])
    ],
    dependencies: [
        .package(path: "../NotaUI")
    ],
    targets: [
        .target(name: "InkKit", dependencies: ["NotaUI"]),
        .testTarget(name: "InkKitTests", dependencies: ["InkKit"])
    ]
)
