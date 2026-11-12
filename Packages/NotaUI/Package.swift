// swift-tools-version: 5.10
import PackageDescription

/// Nota's design system: colour, type, spacing, radius and elevation tokens, the icon set and the shared
/// controls built from them. See DESIGN.md at the repository root.
///
/// Dependency rule: NotaUI depends on nothing of ours.
let package = Package(
    name: "NotaUI",
    platforms: [.iOS("17.5")],
    products: [
        .library(name: "NotaUI", targets: ["NotaUI"])
    ],
    targets: [
        .target(name: "NotaUI", resources: [.process("Resources")])
    ]
)
