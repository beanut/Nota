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
        .testTarget(name: "InkKitTests", dependencies: ["InkKit"]),
        // Performance benchmarks and latency budgets. Not part of the regular test run: CI skips them and
        // a nightly job runs them in Release against a stored baseline (see README › Benchmarks).
        .testTarget(name: "InkKitBenchmarks", dependencies: ["InkKit"], resources: [.copy("Fixtures")])
    ]
)
