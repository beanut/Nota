import CoreGraphics
import Foundation

/// A page's ink and objects frozen at one revision. Snapshots are plain values, so they can be rendered
/// off the main actor while the page keeps changing.
public struct PageSnapshot: Sendable {
    public let pageID: UUID
    /// The page's `revision` (its ink's) when the snapshot was taken.
    public let revision: Int
    /// The page's `objectsRevision` when the snapshot was taken.
    public let objectsRevision: Int
    public let pageSize: PageSize
    public let template: PageTemplate
    public let templateArtwork: TemplateArtwork?
    let strokes: [Stroke]
    /// Lowest `zIndex` first.
    let objects: [any PageObject]

    /// True when the page has no ink and no objects to draw.
    public var isBlank: Bool {
        !strokes.contains { !$0.brush.erases } && !objects.contains(where: PageObjectKinds.isSelectable)
    }
}

public extension CanvasDocument {
    /// The page's current ink and objects, for rendering elsewhere (see `PageRenderer`).
    func snapshot() -> PageSnapshot {
        PageSnapshot(pageID: id, revision: revision, objectsRevision: objectsRevision, pageSize: pageSize,
                     template: template, templateArtwork: template.background == nil ? nil : templateArtwork,
                     strokes: strokes, objects: objects)
    }
}

/// Draws a page's objects and ink with the same code the canvas uses, for thumbnails and other still
/// images. Safe to call from any thread.
public enum PageRenderer {
    /// Draws the page's objects into `ctx` (mapped to canvas space, like `drawInk`), in stacking order,
    /// clipped to the page. Call it between the template and the ink.
    public static func drawObjects(_ page: PageSnapshot, in ctx: CGContext) {
        draw(page.objects, clip: page.pageSize.bounds, in: ctx)
    }

    /// Draws `objects` in canvas space, skipping those outside `visible`.
    static func draw(_ objects: [any PageObject], clip: CGRect, visible: CGRect? = nil, in ctx: CGContext) {
        guard !objects.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: clip)
        for object in objects {
            guard object.bounds.intersects(visible ?? clip) else { continue }
            ctx.saveGState()
            ctx.concatenate(object.transform)
            object.draw(in: ctx)
            ctx.restoreGState()
        }
    }

    /// Draws the page's ink into `ctx`, which must already map canvas space (points from the page's
    /// top-left, y down) onto the destination.
    ///
    /// Ink is composited as one layer over whatever `ctx` already holds, so the pixel eraser removes ink
    /// only and never the paper or template drawn underneath. Ink beyond the page edge is clipped.
    public static func drawInk(_ page: PageSnapshot, in ctx: CGContext) {
        guard !page.isBlank else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: page.pageSize.bounds)
        PencilTexture.prepareContext(ctx)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for stroke in page.strokes {
            let geometry = StrokeRenderer.geometry(for: stroke)
            guard geometry.bounds.intersects(page.pageSize.bounds) else { continue }
            StrokeRenderer.draw(runs: geometry.runs, clip: geometry.bounds.insetBy(dx: -2, dy: -2),
                                brush: stroke.brush, color: stroke.color, in: ctx)
        }
        ctx.endTransparencyLayer()
    }

    /// The page rendered `pixelWidth` pixels wide (height follows the page's aspect ratio) in sRGB: its
    /// objects, then its ink. `background` draws first, in pixel space with the origin at the top-left: fill the paper and its
    /// template there. Returns nil if the bitmap can't be created.
    public static func image(of page: PageSnapshot,
                             pixelWidth: Int,
                             background: (CGContext, CGSize) -> Void = { _, _ in }) -> CGImage? {
        let width = max(1, pixelWidth)
        let height = max(1, Int((CGFloat(width) * page.pageSize.height / page.pageSize.width).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Flip to UIKit's top-left origin, which canvas space shares.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        background(ctx, CGSize(width: width, height: height))
        let scale = CGFloat(width) / page.pageSize.width
        ctx.scaleBy(x: scale, y: scale)
        drawObjects(page, in: ctx)
        drawInk(page, in: ctx)
        return ctx.makeImage()
    }

    /// The page rendered `pixelWidth` pixels wide on its own template, coloured by `palette`.
    public static func image(of page: PageSnapshot, pixelWidth: Int,
                             palette: @escaping (PaperColor) -> PaperPalette) -> CGImage? {
        image(of: page, pixelWidth: pixelWidth) { ctx, size in
            drawTemplate(of: page, in: ctx, scale: size.width / page.pageSize.width, palette: palette(page.template.paper))
        }
    }

    /// Draws the page's template into `ctx` scaled by `scale` (pixels per point), origin top-left, y down.
    public static func drawTemplate(of page: PageSnapshot, in ctx: CGContext, scale: CGFloat, palette: PaperPalette) {
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        TemplateRenderer.draw(page.template, pageSize: page.pageSize, palette: palette, artwork: page.templateArtwork,
                              in: ctx, minimumLineWidth: scale > 0 ? 0.5 / scale : 0)
        ctx.restoreGState()
    }

    /// A PDF of `pages`, one PDF page per page at its own size, each with its template, objects and ink. Templates
    /// (and PDF backgrounds) stay vector; ink is filled outlines, as on the canvas. Nil if there are no
    /// pages or the PDF context can't be made.
    public static func pdf(of pages: [PageSnapshot], title: String? = nil,
                           palette: (PaperColor) -> PaperPalette) -> Data? {
        guard let first = pages.first else { return nil }
        let data = NSMutableData()
        var mediaBox = first.pageSize.bounds
        var info: [CFString: Any] = [kCGPDFContextCreator: "InkKit"]
        if let title {
            info[kCGPDFContextTitle] = title
        }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { return nil }
        for page in pages {
            var box = page.pageSize.bounds
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            // PDF space is y-up; canvas space is y-down.
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            TemplateRenderer.draw(page.template, pageSize: page.pageSize, palette: palette(page.template.paper),
                                  artwork: page.templateArtwork, in: ctx)
            drawObjects(page, in: ctx)
            drawInk(page, in: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
