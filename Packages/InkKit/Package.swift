// swift-tools-version: 5.10
import PackageDescription

/// The drawing engine: Pencil input, brushes, rendering, the page model and the editor view.
///
/// Dependency rule: InkKit depends on nothing of ours. Apps theme its chrome with `InkTheme`.
let package = Package(
    name: "InkKit",
    platforms: [.iOS("17.5")],
    products: [
        .library(name: "InkKit", targets: ["InkKit"])
    ],
    targets: [
        .target(name: "InkKit"),
        .testTarget(name: "InkKitTests", dependencies: ["InkKit"])
    ]
)
