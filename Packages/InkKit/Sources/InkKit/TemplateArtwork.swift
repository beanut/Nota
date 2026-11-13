import CoreGraphics
import Foundation
import ImageIO

/// The bytes of a custom template background, a PDF page or an image, decoded once and ready to draw.
///
/// A page holds it next to its `PageTemplate` (whose `background` names it by `id`); the host stores
/// `data` with the note. A PDF page stays vector: it's drawn as PDF at every zoom and into exported PDFs.
public final class TemplateArtwork: @unchecked Sendable {
    // Immutable after init; CGPDFPage and CGImage are safe to draw from several threads.
    public let id: UUID
    public let kind: TemplateBackground.Kind
    /// The PDF page drawn (from 0); always 0 for an image.
    public let pageIndex: Int
    /// The original file, for saving.
    public let data: Data
    /// Pages in the PDF (1 for an image).
    public let pageCount: Int
    private let document: CGPDFDocument?
    private let pdfPage: CGPDFPage?
    private let image: CGImage?

    /// Decodes `data` as `kind`. Nil if it isn't a readable PDF (with a page `pageIndex`) or image.
    public init?(id: UUID = UUID(), kind: TemplateBackground.Kind, data: Data, pageIndex: Int = 0) {
        self.id = id
        self.kind = kind
        self.data = data
        switch kind {
        case .pdf:
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  !document.isEncrypted || document.isUnlocked,
                  document.numberOfPages > 0
            else { return nil }
            let index = min(max(pageIndex, 0), document.numberOfPages - 1)
            guard let page = document.page(at: index + 1) else { return nil }
            self.document = document
            pdfPage = page
            image = nil
            self.pageIndex = index
            pageCount = document.numberOfPages
        case .image:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            document = nil
            pdfPage = nil
            self.image = image
            self.pageIndex = 0
            pageCount = 1
        }
    }

    /// Reads a file's bytes as a PDF if they look like one, otherwise as an image.
    public convenience init?(id: UUID = UUID(), data: Data, pageIndex: Int = 0) {
        let isPDF = data.starts(with: Array("%PDF".utf8))
        self.init(id: id, kind: isPDF ? .pdf : .image, data: data, pageIndex: pageIndex)
    }

    /// The background a template uses to name this artwork.
    public var background: TemplateBackground {
        TemplateBackground(id: id, kind: kind, pageIndex: pageIndex)
    }

    /// The artwork's size in points (a PDF page's crop box, turned by its rotation; an image's pixels).
    public var size: CGSize {
        if let pdfPage {
            let box = pdfPage.getBoxRect(.cropBox)
            return pdfPage.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        }
        if let image {
            return CGSize(width: image.width, height: image.height)
        }
        return .zero
    }

    /// Draws the artwork as large as fits inside `rect`, centred, keeping its proportions. `ctx` is y-down.
    func draw(in rect: CGRect, ctx: CGContext) {
        let size = size
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let target = CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Both PDF and CGImage drawing expect y-up: flip about the target.
        ctx.translateBy(x: 0, y: target.maxY + target.minY)
        ctx.scaleBy(x: 1, y: -1)
        if let image {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: target)
        } else if let pdfPage {
            let box = pdfPage.getBoxRect(.cropBox)
            ctx.clip(to: target)
            ctx.translateBy(x: target.midX, y: target.midY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.rotate(by: -CGFloat(pdfPage.rotationAngle) * .pi / 180)
            ctx.translateBy(x: -box.midX, y: -box.midY)
            ctx.drawPDFPage(pdfPage)
        }
    }
}
