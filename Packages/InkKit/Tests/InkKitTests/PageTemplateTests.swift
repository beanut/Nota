import CoreGraphics
import Foundation
import ImageIO
@testable import InkKit
import Testing

@MainActor
@Suite("Page templates")
struct PageTemplateTests {
    @Test func roundTripsThroughJSON() throws {
        var template = PageTemplate.preset(.cornell).on(.dark)
        template.background = TemplateBackground(kind: .pdf, pageIndex: 2)
        let data = try JSONEncoder().encode(template)
        #expect(try JSONDecoder().decode(PageTemplate.self, from: data) == template)
    }

    /// A template written by a newer version (an unknown pattern or paper) mustn't make a page unreadable.
    @Test func unknownValuesDecodeAsBlankPaper() throws {
        let json = #"{"pattern": "hexagons", "spacing": 12, "paper": "neon", "margins": {"top": 4, "left": 0, "bottom": 0, "right": 0}}"#
        let template = try JSONDecoder().decode(PageTemplate.self, from: Data(json.utf8))
        #expect(template.pattern == .blank)
        #expect(template.paper == .white)
        #expect(template.spacing == 12)
        #expect(template.margins.top == 4)
    }

    @Test func spacingIsClamped() {
        #expect(PageTemplate(pattern: .ruled, spacing: 0).spacing == 2)
        #expect(PageTemplate(pattern: .ruled, spacing: 5000).spacing == 200)
        #expect(PageTemplate(pattern: .ruled, spacing: .nan).spacing == 18)
    }

    @Test func presetsAreRecognisedOnAnyPaper() {
        for preset in PageTemplate.Preset.allCases {
            #expect(preset.template.preset == preset)
            #expect(preset.template.on(.dark).preset == preset)
        }
        var custom = PageTemplate.preset(.collegeRuled)
        custom.spacing = 30
        #expect(custom.preset == nil)
        #expect(custom.title == "Custom")
        var background = PageTemplate.blank
        background.background = TemplateBackground(kind: .image)
        #expect(background.preset == nil)
        #expect(!background.isPlain)
        #expect(PageTemplate.blank.isPlain)
    }

    @Test func presetsHaveDistinctTemplates() {
        let templates = PageTemplate.Preset.allCases.map(\.template)
        #expect(Set(templates).count == templates.count)
    }

    // MARK: Line metrics

    @Test func ruledLinesStartAtTheTopMarginAndKeepTheirSpacing() throws {
        let template = PageTemplate.preset(.collegeRuled)
        let metrics = template.lineMetrics(on: .letter)
        let spacing = try #require(metrics.lineSpacing)
        #expect(spacing == 20.25) // 9/32 in
        #expect(metrics.baselines.first == template.margins.top)
        #expect(try #require(metrics.baselines.last) <= 792 - template.margins.bottom)
        for (a, b) in zip(metrics.baselines, metrics.baselines.dropFirst()) {
            #expect(abs(b - a - spacing) < 0.001)
        }
        // Writing starts right of the margin rule.
        #expect(metrics.writingArea.minX == template.margins.left)
    }

    @Test func narrowerRulingFitsMoreLines() {
        let narrow = PageTemplate.preset(.narrowRuled).lineMetrics(on: .letter).baselines.count
        let college = PageTemplate.preset(.collegeRuled).lineMetrics(on: .letter).baselines.count
        let wide = PageTemplate.preset(.wideRuled).lineMetrics(on: .letter).baselines.count
        #expect(narrow > college && college > wide)
    }

    @Test func gridIsCentredInItsMargins() throws {
        let template = PageTemplate.preset(.largeGrid)
        let metrics = template.lineMetrics(on: .a4)
        #expect(metrics.gridSpacing == template.spacing)
        let first = try #require(metrics.baselines.first), last = try #require(metrics.baselines.last)
        #expect(abs(first - (PageSize.a4.height - last)) < 0.001)
    }

    @Test func cornellHasCuesNotesAndSummary() {
        let metrics = PageTemplate.preset(.cornell).lineMetrics(on: .letter)
        #expect(metrics.regions.count == 3)
        let cues = metrics.regions[0], notes = metrics.regions[1], summary = metrics.regions[2]
        #expect(cues.maxX == notes.minX)
        #expect(cues.width < notes.width)
        #expect(summary.minY == notes.maxY)
        #expect(metrics.writingArea == notes)
        #expect(!metrics.baselines.isEmpty)
        #expect(metrics.baselines.allSatisfy { abs($0 - summary.minY) > 1 }, "no rule on the summary divider")
    }

    @Test func musicStavesHaveFiveLines() throws {
        let template = PageTemplate.preset(.musicStaff)
        let staves = TemplateLayout.staves(template, page: PageSize.letter.bounds)
        #expect(staves.count >= 6)
        #expect(staves.allSatisfy { $0.count == 5 })
        let last = try #require(staves.last?.last)
        #expect(last <= 792 - template.margins.bottom + 0.001)
        #expect(template.lineMetrics(on: .letter).regions.count == staves.count)
    }

    @Test func todoRowsHaveACheckboxLeftOfTheirLine() {
        for row in TemplateLayout.todoRows(.preset(.todo), page: PageSize.letter.bounds) {
            #expect(row.checkbox.maxX < row.line.minX)
            #expect(row.checkbox.maxY < row.line.minY)
        }
    }

    @Test func plannersHaveADayCellEach() {
        let weekly = PageTemplate.preset(.weeklyPlanner).lineMetrics(on: .letter)
        #expect(weekly.regions.count == 1 + 8) // header, seven days and notes
        let monthly = PageTemplate.preset(.monthlyPlanner).lineMetrics(on: .letter)
        #expect(monthly.regions.count == 1 + 42)
    }

    @Test func weekdaysStartOnTheCalendarsFirstDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        let names = TemplateLayout.weekdayNames(calendar, short: true)
        #expect(names.first == "Mon")
        #expect(names.last == "Sun")
    }

    // MARK: Geometry

    @Test func repeatingPatternsOnlyBuildWhatsVisible() {
        let huge = PageSize(width: 14400, height: 14400)
        let template = PageTemplate.preset(.dots)
        let all = TemplateGeometry(template, page: huge.bounds, visible: huge.bounds)
        let corner = TemplateGeometry(template, page: huge.bounds, visible: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(all.dots.count > 1_000_000)
        #expect(corner.dots.count < 400)
    }

    @Test func stepsStayInsideTheirRange() {
        let values = TemplateGeometry.steps(from: 10, to: 100, by: 10, within: 25 ... 61)
        #expect(values == [30, 40, 50, 60])
        #expect(TemplateGeometry.steps(from: 0, to: 10, by: 0, within: 0 ... 10).isEmpty)
    }

    // MARK: Rendering

    @Test func rulesAreDrawnOnTheBaselines() throws {
        let template = PageTemplate.preset(.wideRuled)
        let palette = PaperPalette.standard(.white)
        let image = try #require(render(template, palette: palette, scale: 2))
        let baseline = try #require(template.lineMetrics(on: .letter).baselines.dropFirst(3).first)
        let onLine = pixel(image, x: 1000, y: Int(baseline * 2))
        let between = pixel(image, x: 1000, y: Int((baseline + template.spacing / 2) * 2))
        #expect(between == .white)
        #expect(onLine != .white)
        #expect(onLine.blue > onLine.red, "rule colour, not the margin's")
    }

    @Test func darkPaperIsDark() throws {
        let image = try #require(render(PageTemplate.preset(.dots).on(.dark), palette: .standard(.dark), scale: 1))
        #expect(pixel(image, x: 5, y: 5).red < 60)
    }

    @Test func pageRendererDrawsTheSnapshotsTemplate() throws {
        let doc = CanvasDocument(pageSize: PageSize(width: 100, height: 100),
                                 template: PageTemplate(pattern: .grid, spacing: 10))
        let snapshot = doc.snapshot()
        let image = try #require(PageRenderer.image(of: snapshot, pixelWidth: 100) { .standard($0) })
        // Grid lines every 10 pt, starting on the edge; the cell centres are paper.
        #expect(pixel(image, x: 15, y: 15) == .white)
        #expect(pixel(image, x: 15, y: 50) != .white)
    }

    // MARK: Artwork

    @Test func imageArtworkDecodesAndDraws() throws {
        let png = try makePNG(red: 1, green: 0, blue: 0)
        let artwork = try #require(TemplateArtwork(data: png))
        #expect(artwork.kind == .image)
        #expect(artwork.size == CGSize(width: 8, height: 8))
        var template = PageTemplate.blank
        template.background = artwork.background
        let image = try #require(render(template, palette: .standard(.white), artwork: artwork, scale: 0.25,
                                        page: PageSize(width: 400, height: 400)))
        let centre = pixel(image, x: 50, y: 50)
        #expect(centre.red > 200 && centre.green < 50)
    }

    @Test func artworkThatDoesntMatchTheTemplateIsIgnored() throws {
        let artwork = try #require(try TemplateArtwork(data: makePNG(red: 1, green: 0, blue: 0)))
        var template = PageTemplate.blank
        template.background = TemplateBackground(kind: .image) // a different id
        let image = try #require(render(template, palette: .standard(.white), artwork: artwork, scale: 0.25,
                                        page: PageSize(width: 400, height: 400)))
        #expect(pixel(image, x: 50, y: 50) == .white)
    }

    @Test func garbageIsNotArtwork() {
        #expect(TemplateArtwork(data: Data("not an image".utf8)) == nil)
        #expect(TemplateArtwork(kind: .pdf, data: Data("%PDF-1.7 broken".utf8)) == nil)
    }

    // MARK: PDF

    @Test func exportsOnePDFPagePerPageWithItsSizeAndTemplate() throws {
        let first = CanvasDocument(pageSize: .letter, template: .preset(.cornell))
        let second = CanvasDocument(pageSize: .a5.landscape, template: PageTemplate.preset(.dots).on(.dark))
        let snapshots = [first.snapshot(), second.snapshot()]
        let data = try #require(PageRenderer.pdf(of: snapshots, title: "Test") { .standard($0) })

        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 2)
        let page1 = try #require(document.page(at: 1)), page2 = try #require(document.page(at: 2))
        #expect(page1.getBoxRect(.mediaBox).size == PageSize.letter.size)
        #expect(page2.getBoxRect(.mediaBox).size == PageSize.a5.landscape.size)

        // A PDF exported from a PDF-backed page can itself be a template background, and draws its lines.
        let artwork = try #require(TemplateArtwork(data: data, pageIndex: 1))
        #expect(artwork.kind == .pdf)
        #expect(artwork.pageCount == 2)
        #expect(artwork.pageIndex == 1)
        #expect(artwork.size == PageSize.a5.landscape.size)
        var template = PageTemplate.blank
        template.background = artwork.background
        let image = try #require(render(template, palette: .standard(.white), artwork: artwork, scale: 1,
                                        page: .a5.landscape))
        #expect(pixel(image, x: 3, y: 3).red < 60, "the exported page's dark paper")
    }
}

// MARK: - Helpers

private func render(_ template: PageTemplate, palette: PaperPalette, artwork: TemplateArtwork? = nil,
                    scale: CGFloat, page: PageSize = .letter) -> CGImage? {
    let width = Int(page.width * scale), height = Int(page.height * scale)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)
    TemplateRenderer.draw(template, pageSize: page, palette: palette, artwork: artwork, in: ctx,
                          minimumLineWidth: 1 / scale)
    return ctx.makeImage()
}

private struct RGB: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    static let white = RGB(red: 255, green: 255, blue: 255)
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> RGB {
    var data = [UInt8](repeating: 0, count: 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Bitmap rows run bottom-up in CG space, so row `y` from the top sits at height - 1 - y.
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return RGB(red: data[0], green: data[1], blue: data[2])
}

private func makePNG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
