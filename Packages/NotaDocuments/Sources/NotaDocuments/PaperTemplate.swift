import NotaCore
import NotaUI
import UIKit

/// The paper and its ruling, drawn with Core Graphics so the SwiftUI placeholder and the rendered cover
/// match exactly. Measurements follow Figma's 190 pt-wide Paper and scale with `size`.
public enum PaperTemplate {
    private static let surface = NotaUIColor.paperSurface.cgColor
    private static let rule = NotaUIColor.paperRule.cgColor

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
            var y = 36 * unit
            while y < size.height {
                ctx.fill(CGRect(x: 0, y: y, width: size.width, height: max(0.5, 0.75 * unit)))
                y += 10 * unit
            }
        case .dotted:
            let step = 12 * unit
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
            let step = 12 * unit
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
