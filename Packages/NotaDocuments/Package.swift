// swift-tools-version: 5.10
import PackageDescription

/// Rendered views of notes: cover thumbnails and paper templates. PDF, import/export and the scanner join
/// it in later milestones.
///
/// Dependency rule: a feature package; it depends on NotaCore (and InkKit, NotaUI), never on another
/// feature package or the app.
let package = Package(
    name: "NotaDocuments",
    platforms: [.iOS("17.5")],
    products: [
        .library(name: "NotaDocuments", targets: ["NotaDocuments"])
    ],
    dependencies: [
        .package(path: "../InkKit"),
        .package(path: "../NotaCore"),
        .package(path: "../NotaUI")
    ],
    targets: [
        .target(name: "NotaDocuments", dependencies: ["InkKit", "NotaCore", "NotaUI"])
    ]
)
