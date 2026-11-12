// swift-tools-version: 5.10
import PackageDescription

/// Nota's domain: the `Note` and `Folder` models, `DocumentStore`, the note package and its manifest.
///
/// Dependency rule: NotaCore depends on InkKit only. It knows nothing about UI or the design system.
let package = Package(
    name: "NotaCore",
    platforms: [.iOS("17.5")],
    products: [
        .library(name: "NotaCore", targets: ["NotaCore"])
    ],
    dependencies: [
        .package(path: "../InkKit")
    ],
    targets: [
        .target(name: "NotaCore", dependencies: ["InkKit"]),
        .testTarget(name: "NotaCoreTests", dependencies: ["NotaCore"])
    ]
)
