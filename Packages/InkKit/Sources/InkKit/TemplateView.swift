import UIKit

/// The page's template, between the paper and the ink. It's redrawn as vectors at the canvas's transform
/// whenever the page moves or zooms, so lines stay one crisp width at every zoom instead of scaling a bitmap.
///
/// Only what's on screen is drawn (`TemplateRenderer` skips pattern outside the visible rect), and nothing
/// is drawn while ink is being written: the view only redraws for pan, zoom and template changes.
final class TemplateView: UIView {
    /// Everything needed to draw one page's template.
    struct Paper: Equatable {
        var template = PageTemplate.default
        var artwork: TemplateArtwork?
        var palette = PaperPalette.standard(.white)
        var pageSize = PageSize.default

        static func == (a: Paper, b: Paper) -> Bool {
            a.template == b.template && a.artwork === b.artwork && a.palette == b.palette && a.pageSize == b.pageSize
        }

        /// Draws the template in view space at `transform`, limited to `viewRect` (`scale`: pixels per
        /// point). Also the live layer's backdrop under highlighter strokes, with `fillsPaper`.
        func draw(at transform: ViewTransform, viewRect: CGRect, scale: CGFloat, fillsPaper: Bool, in ctx: CGContext) {
            guard transform.scale > 0 else { return }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.concatenate(transform.affine)
            TemplateRenderer.draw(template, pageSize: pageSize, palette: palette, artwork: artwork, in: ctx,
                                  visibleRect: transform.toCanvas(viewRect),
                                  minimumLineWidth: 1 / (transform.scale * max(scale, 1)), fillsPaper: fillsPaper)
        }
    }

    private(set) var paper = Paper()
    private var canvasTransform = ViewTransform()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `document`'s template in `theme`'s colours for its paper, and returns the paper's surface colour.
    func show(_ document: CanvasDocument, theme: InkTheme) -> CGColor {
        let paper = Paper(template: document.template, artwork: document.templateArtwork,
                          palette: theme.palette(for: document.template.paper), pageSize: document.pageSize)
        if paper != self.paper {
            self.paper = paper
            isHidden = paper.template.isPlain
            setNeedsDisplay()
        }
        return paper.palette.surface
    }

    /// Makes `live` draw this paper and template as the opaque backdrop it previews multiply ink over.
    func provideBackdrop(for live: LiveInkView) {
        live.drawPaper = { [weak self] ctx, transform, rect in
            guard let self else { return }
            paper.draw(at: transform, viewRect: rect, scale: contentScaleFactor, fillsPaper: true, in: ctx)
        }
    }

    /// Follows the canvas to `transform`.
    func follow(_ transform: ViewTransform) {
        guard transform != canvasTransform else { return }
        canvasTransform = transform
        if !isHidden {
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        paper.draw(at: canvasTransform, viewRect: rect, scale: contentScaleFactor, fillsPaper: false, in: ctx)
    }
}
