import SwiftUI

/// The tool picker's realistic tool artwork (Figma **ToolPicker/Illustration/***), drawn at 34 × 34 pt.
///
/// The pens, pencils, highlighter, eraser and ruler are drawn upright in their asset and laid at an angle
/// here, exactly as Figma places them: each is rotated about its centre and nudged so its bounding box lands
/// where the design's does. The lasso, shapes and text box are flat 34 pt assets. No shadow is drawn here:
/// the tool picker adds it (and lifts it while the tool is selected).
public enum NotaToolIllustration: String, CaseIterable, Sendable {
    case pen, marker, pencil, crayon, fountainPen, highlighter, eraser, lasso, ruler, shapes, textBox

    /// The illustration's box.
    public static let size: CGFloat = 34

    var assetName: String {
        "illustration.\(rawValue.lowercased())"
    }

    /// How an asset is laid in the box: its natural size, its rotation, and its centre's offset from the
    /// box's centre.
    struct Placement {
        let size: CGSize
        let degrees: Double
        let offset: CGSize

        init(_ width: CGFloat, _ height: CGFloat, degrees: Double = 35, dx: CGFloat = 0, dy: CGFloat = 0) {
            size = CGSize(width: width, height: height)
            self.degrees = degrees
            offset = CGSize(width: dx, height: dy)
        }
    }

    var placement: Placement {
        switch self {
        case .pen: Placement(5.578, 29.591, dx: -0.046, dy: 0.066)
        case .marker: Placement(7.172, 29.617, dx: -0.075, dy: 0.109)
        case .pencil: Placement(5.313, 28.422, dx: -0.381, dy: 0.544)
        case .crayon: Placement(5.313, 27.359, dx: -0.077, dy: 0.109)
        case .fountainPen: Placement(5.313, 28.953, dx: 0.381, dy: -0.544)
        case .highlighter: Placement(7.969, 29.484, dx: 0.075, dy: -0.109)
        case .eraser: Placement(8.766, 27.227, dx: -0.153, dy: 0.218)
        case .ruler: Placement(6.694, 31.131, degrees: 45)
        case .lasso, .shapes, .textBox: Placement(Self.size, Self.size, degrees: 0)
        }
    }
}

/// A tool illustration in its 34 pt box.
public struct NotaToolIllustrationView: View {
    let illustration: NotaToolIllustration

    public init(_ illustration: NotaToolIllustration) {
        self.illustration = illustration
    }

    public var body: some View {
        let placement = illustration.placement
        Image(illustration.assetName, bundle: .module)
            .resizable()
            .renderingMode(.original)
            .frame(width: placement.size.width, height: placement.size.height)
            .rotationEffect(.degrees(placement.degrees))
            .offset(placement.offset)
            .frame(width: NotaToolIllustration.size, height: NotaToolIllustration.size)
            .accessibilityHidden(true)
    }
}
