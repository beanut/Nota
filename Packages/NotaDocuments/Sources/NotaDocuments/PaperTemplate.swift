import InkKit
import NotaUI
import UIKit

public extension PaperPalette {
    /// Nota's paper colours, from NotaUI's paper tokens. Fixed colours: paper doesn't follow dark mode.
    static func nota(_ paper: PaperColor) -> PaperPalette {
        switch paper {
        case .white:
            PaperPalette(surface: NotaUIColor.paperSurface.cgColor, rule: NotaUIColor.paperRule.cgColor,
                         accent: NotaUIColor.paperMargin.cgColor, label: NotaUIColor.paperLabel.cgColor)
        case .cream:
            PaperPalette(surface: NotaUIColor.paperCreamSurface.cgColor, rule: NotaUIColor.paperCreamRule.cgColor,
                         accent: NotaUIColor.paperMargin.cgColor, label: NotaUIColor.paperLabel.cgColor)
        case .dark:
            PaperPalette(surface: NotaUIColor.paperDarkSurface.cgColor, rule: NotaUIColor.paperDarkRule.cgColor,
                         accent: NotaUIColor.paperDarkMargin.cgColor, label: NotaUIColor.paperDarkLabel.cgColor)
        }
    }

    /// Every paper's Nota palette, for `InkTheme.nota`.
    static let notaPalettes: [PaperColor: PaperPalette] = Dictionary(
        uniqueKeysWithValues: PaperColor.allCases.map { ($0, nota($0)) }
    )
}

/// A template drawn as a library placeholder: the bare template of a Letter page, scaled to `size`, for a
/// note whose cover hasn't been rendered (no ink yet, or still loading).
public enum PaperTemplate {
    /// Fills `size` (origin top-left, y down) with `template` as it looks on a Letter page.
    public static func draw(_ template: PageTemplate, in ctx: CGContext, size: CGSize) {
        guard size.width > 0 else { return }
        let page = PageSize.letter
        let scale = size.width / page.width
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(PaperPalette.nota(template.paper).surface)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        TemplateRenderer.draw(template, pageSize: page, palette: .nota(template.paper), in: ctx,
                              minimumLineWidth: 0.5 / scale)
    }
}
