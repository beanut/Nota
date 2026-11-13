import InkKit
import NotaCore
import NotaUI
import UIKit

/// The paper and its ruling, drawn with Core Graphics so the SwiftUI placeholder and the rendered cover
/// match exactly. Measurements follow Figma's 190 pt-wide Paper and scale with `size`.
public enum PaperTemplate {
    private static let surface = NotaUIColor.paperSurface.cgColor
    private static let rule = NotaUIColor.paperRule.cgColor

    /// Figma Paper / Ruled: the first rule 36 units down, then one every 10, on a 190-unit-wide page.
    private static let ruledFirst: CGFloat = 36
    private static let ruledSpacing: CGFloat = 10
    /// Dotted and grid paper: a dot or line every 12 units.
    private static let gridStep: CGFloat = 12

    /// Where `paper`'s lines of writing are on a page of `size`, for the editor's zoom window: the rules
    /// of lined paper, or every row of dots or grid. Nil for plain paper, which has none.
    public static func writingLines(for paper: PaperStyle, size: CGSize) -> WritingLines? {
        let unit = size.width / 190
        switch paper {
        case .plain:
            return nil
        case .lined:
            let spacing = ruledSpacing * unit
            return WritingLines(spacing: spacing, firstBaseline: ruledFirst * unit,
                                left: spacing, right: size.width - spacing)
        case .dotted, .grid:
            let step = gridStep * unit
            return WritingLines(spacing: step, firstBaseline: 2 * step, left: step, right: size.width - step)
        }
    }

    /// Fills `size` (origin top-left, y down) with paper and draws `paper`'s ruling over it.
    public static func draw(_ paper: PaperStyle, in ctx: CGContext, size: CGSize) {
        let unit = size.width / 190
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(surface)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(rule)

        switch paper {
        case .plain:
            break
        case .lined:
            // Figma Paper / Ruled: first rule at 36 pt, then one every 10 pt.
            var y = ruledFirst * unit
            while y < size.height {
                ctx.fill(CGRect(x: 0, y: y, width: size.width, height: max(0.5, 0.75 * unit)))
                y += ruledSpacing * unit
            }
        case .dotted:
            let step = gridStep * unit
            let r = max(0.6, 1 * unit)
            var y = step
            while y < size.height {
                var x = step
                while x < size.width {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    x += step
                }
                y += step
            }
        case .grid:
            let step = gridStep * unit
            let line = max(0.5, 0.5 * unit)
            var x = step
            while x < size.width {
                ctx.fill(CGRect(x: x, y: 0, width: line, height: size.height))
                x += step
            }
            var y = step
            while y < size.height {
                ctx.fill(CGRect(x: 0, y: y, width: size.width, height: line))
                y += step
            }
        }
    }
}
