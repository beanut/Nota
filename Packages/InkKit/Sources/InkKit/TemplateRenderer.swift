import CoreGraphics
import CoreText
import Foundation

/// Draws a `PageTemplate` with Core Graphics vectors: the canvas draws it under the ink at the current zoom,
/// `PageRenderer` under thumbnails, and PDF export into the PDF itself, so it's crisp everywhere.
///
/// Safe to call from any thread.
public enum TemplateRenderer {
    /// Line weights in page points. `minimumLineWidth` keeps them at least a pixel wide when zoomed out.
    enum Weight {
        static let rule: CGFloat = 0.6
        static let grid: CGFloat = 0.5
        static let accent: CGFloat = 0.9
        static let frame: CGFloat = 0.75
        static let dotRadius: CGFloat = 0.85
    }

    /// Draws `template` into `ctx`, which must map canvas space (points from the page's top-left, y down)
    /// onto the destination.
    ///
    /// - Parameters:
    ///   - artwork: the bytes of `template.background`; ignored unless its id matches.
    ///   - visibleRect: the part of the page (canvas space) that needs drawing. Repeating patterns skip
    ///     everything outside it, so a zoomed-in view of a huge page stays cheap.
    ///   - minimumLineWidth: the thinnest line to draw, in canvas units; pass one device pixel.
    ///   - fillsPaper: false when the paper colour is already there (the canvas's page layer).
    ///   - calendar: weekday names and order for planners.
    public static func draw(_ template: PageTemplate, pageSize: PageSize, palette: PaperPalette,
                            artwork: TemplateArtwork? = nil, in ctx: CGContext, visibleRect: CGRect? = nil,
                            minimumLineWidth: CGFloat = 0, fillsPaper: Bool = true, calendar: Calendar = .current) {
        let page = pageSize.bounds
        let visible = (visibleRect ?? page).intersection(page)
        guard !visible.isNull, !visible.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: page)
        if fillsPaper {
            ctx.setFillColor(palette.surface)
            ctx.fill(visible)
        }
        if let artwork, let background = template.background, artwork.id == background.id {
            artwork.draw(in: page, ctx: ctx)
        }
        let geometry = TemplateGeometry(template, page: page, visible: visible.insetBy(dx: -2, dy: -2),
                                        calendar: calendar)
        geometry.draw(in: ctx, palette: palette, minimumLineWidth: minimumLineWidth)
    }
}

// MARK: - Geometry

/// The marks a template makes on one page, in canvas space.
struct TemplateGeometry {
    struct Line {
        var from: CGPoint
        var to: CGPoint
    }

    struct Label {
        var text: String
        /// Left end of the baseline, or its centre when `centered`.
        var origin: CGPoint
        var size: CGFloat
        var centered = false
    }

    var rules: [Line] = []
    var gridLines: [Line] = []
    var accents: [Line] = []
    /// Stroked in the rule colour: planner cells, checkboxes.
    var frames: [CGRect] = []
    var dots: [CGPoint] = []
    var labels: [Label] = []

    init(_ template: PageTemplate, page: CGRect, visible: CGRect, calendar: Calendar = .current) {
        let s = template.spacing
        let m = template.margins
        let inner = CGRect(x: m.left, y: m.top, width: page.width - m.left - m.right,
                           height: page.height - m.top - m.bottom)
        switch template.pattern {
        case .blank:
            break
        case .ruled:
            rules = Self.horizontal(TemplateLayout.ruledBaselines(template, page: page), from: 0, to: page.width, in: visible)
            if template.marginRule {
                accents.append(Line(from: CGPoint(x: m.left, y: 0), to: CGPoint(x: m.left, y: page.height)))
            }
        case .grid:
            let grid = TemplateLayout.grid(template, page: page)
            for x in Self.steps(from: grid.origin.x, to: inner.maxX, by: s, within: visible.minX ... visible.maxX) {
                gridLines.append(Line(from: CGPoint(x: x, y: inner.minY), to: CGPoint(x: x, y: inner.maxY)))
            }
            for y in Self.steps(from: grid.origin.y, to: inner.maxY, by: s, within: visible.minY ... visible.maxY) {
                gridLines.append(Line(from: CGPoint(x: inner.minX, y: y), to: CGPoint(x: inner.maxX, y: y)))
            }
        case .dots:
            let grid = TemplateLayout.grid(template, page: page)
            let xs = Self.steps(from: grid.origin.x, to: inner.maxX, by: s, within: visible.minX ... visible.maxX)
            for y in Self.steps(from: grid.origin.y, to: inner.maxY, by: s, within: visible.minY ... visible.maxY) {
                dots.append(contentsOf: xs.map { CGPoint(x: $0, y: y) })
            }
        case .cornell:
            addCornell(template, page: page, visible: visible)
        case .musicStaff:
            for staff in TemplateLayout.staves(template, page: page) {
                rules += staff.map { Line(from: CGPoint(x: inner.minX, y: $0), to: CGPoint(x: inner.maxX, y: $0)) }
            }
        case .isometric:
            addIsometric(spacing: s, page: page, visible: visible)
        case .todo:
            for row in TemplateLayout.todoRows(template, page: page) where row.line.maxY >= visible.minY && row.line.minY <= visible.maxY {
                frames.append(row.checkbox)
                rules.append(Line(from: CGPoint(x: row.line.minX, y: row.line.minY), to: CGPoint(x: row.line.maxX, y: row.line.minY)))
            }
        case .weeklyPlanner:
            addWeekly(template, page: page, calendar: calendar)
        case .monthlyPlanner:
            addMonthly(template, page: page, calendar: calendar)
        }
    }

    // MARK: Patterns

    private mutating func addCornell(_ template: PageTemplate, page: CGRect, visible: CGRect) {
        let layout = TemplateLayout.cornell(template, page: page)
        accents.append(Line(from: CGPoint(x: 0, y: layout.cues.minY), to: CGPoint(x: page.width, y: layout.cues.minY)))
        accents.append(Line(from: CGPoint(x: layout.cues.maxX, y: layout.cues.minY),
                            to: CGPoint(x: layout.cues.maxX, y: layout.cues.maxY)))
        accents.append(Line(from: CGPoint(x: 0, y: layout.summary.minY), to: CGPoint(x: page.width, y: layout.summary.minY)))
        rules = Self.horizontal(TemplateLayout.cornellBaselines(template, page: page), from: 0, to: page.width, in: visible)
    }

    /// Lines at 30° either way and verticals, meeting in equilateral triangles of side `spacing`.
    private mutating func addIsometric(spacing s: CGFloat, page: CGRect, visible: CGRect) {
        let dx = s * sqrt(3) / 2 // gap between verticals
        let slope = tan(CGFloat.pi / 6)
        for x in Self.steps(from: 0, to: page.width, by: dx, within: visible.minX ... visible.maxX) {
            gridLines.append(Line(from: CGPoint(x: x, y: page.minY), to: CGPoint(x: x, y: page.maxY)))
        }
        // y = ±slope·x + c. Each family's intercepts that cross the visible rect, every `s`.
        for sign: CGFloat in [1, -1] {
            let corners = [visible.minX, visible.maxX].flatMap { x in
                [visible.minY, visible.maxY].map { y in y - sign * slope * x }
            }
            guard let lo = corners.min(), let hi = corners.max() else { continue }
            var c = (lo / s).rounded(.down) * s
            while c <= hi {
                gridLines.append(Line(from: CGPoint(x: visible.minX, y: sign * slope * visible.minX + c),
                                      to: CGPoint(x: visible.maxX, y: sign * slope * visible.maxX + c)))
                c += s
            }
        }
    }

    private mutating func addWeekly(_ template: PageTemplate, page: CGRect, calendar: Calendar) {
        let layout = TemplateLayout.weekly(template, page: page)
        accents.append(Line(from: CGPoint(x: layout.header.minX, y: layout.header.maxY),
                            to: CGPoint(x: layout.header.maxX, y: layout.header.maxY)))
        let names = TemplateLayout.weekdayNames(calendar, short: false) + [String(localized: "Notes")]
        let size = min(9, template.spacing * 0.42)
        for (cell, name) in zip(layout.cells, names) {
            frames.append(cell)
            labels.append(Label(text: name.localizedUppercase, origin: CGPoint(x: cell.minX + 6, y: cell.minY + 6 + size),
                                size: size))
        }
    }

    private mutating func addMonthly(_ template: PageTemplate, page: CGRect, calendar: Calendar) {
        let layout = TemplateLayout.monthly(template, page: page)
        accents.append(Line(from: CGPoint(x: layout.header.minX, y: layout.header.maxY),
                            to: CGPoint(x: layout.header.maxX, y: layout.header.maxY)))
        let names = TemplateLayout.weekdayNames(calendar, short: true)
        let size = min(9, layout.weekdays.height * 0.5)
        let columnWidth = layout.weekdays.width / 7
        for (i, name) in names.enumerated() {
            labels.append(Label(text: name.localizedUppercase,
                                origin: CGPoint(x: layout.weekdays.minX + (CGFloat(i) + 0.5) * columnWidth,
                                                y: layout.weekdays.midY + size * 0.35),
                                size: size, centered: true))
        }
        let grid = layout.days
        frames.append(grid)
        for i in 1 ..< 7 {
            let x = grid.minX + CGFloat(i) * grid.width / 7
            gridLines.append(Line(from: CGPoint(x: x, y: grid.minY), to: CGPoint(x: x, y: grid.maxY)))
        }
        for i in 1 ..< 6 {
            let y = grid.minY + CGFloat(i) * grid.height / 6
            gridLines.append(Line(from: CGPoint(x: grid.minX, y: y), to: CGPoint(x: grid.maxX, y: y)))
        }
    }

    // MARK: Helpers

    private static func horizontal(_ ys: [CGFloat], from x0: CGFloat, to x1: CGFloat, in visible: CGRect) -> [Line] {
        ys.filter { $0 >= visible.minY && $0 <= visible.maxY }
            .map { Line(from: CGPoint(x: x0, y: $0), to: CGPoint(x: x1, y: $0)) }
    }

    /// `start`, `start + step`, … up to `end`, keeping only values within `range`.
    static func steps(from start: CGFloat, to end: CGFloat, by step: CGFloat, within range: ClosedRange<CGFloat>) -> [CGFloat] {
        guard step > 0, start <= end else { return [] }
        let first = max(0, ((range.lowerBound - start) / step).rounded(.up))
        let last = min(((end - start) / step).rounded(.down), ((range.upperBound - start) / step).rounded(.down))
        guard first <= last else { return [] }
        return (Int(first) ... Int(last)).map { start + CGFloat($0) * step }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, palette: PaperPalette, minimumLineWidth: CGFloat) {
        let w = TemplateRenderer.Weight.self
        stroke(rules, color: palette.rule, width: max(w.rule, minimumLineWidth), in: ctx)
        stroke(gridLines, color: palette.rule, width: max(w.grid, minimumLineWidth), in: ctx)
        if !frames.isEmpty {
            ctx.setStrokeColor(palette.rule)
            ctx.setLineWidth(max(w.frame, minimumLineWidth))
            ctx.addRects(frames)
            ctx.strokePath()
        }
        if !dots.isEmpty {
            let r = max(w.dotRadius, minimumLineWidth) // at least two pixels across
            let path = CGMutablePath()
            for p in dots {
                path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
            ctx.setFillColor(palette.rule)
            ctx.addPath(path)
            ctx.fillPath()
        }
        stroke(accents, color: palette.accent, width: max(w.accent, minimumLineWidth), in: ctx)
        for label in labels {
            draw(label, color: palette.label, in: ctx)
        }
    }

    private func stroke(_ lines: [Line], color: CGColor, width: CGFloat, in ctx: CGContext) {
        guard !lines.isEmpty else { return }
        let path = CGMutablePath()
        for line in lines {
            path.move(to: line.from)
            path.addLine(to: line.to)
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func draw(_ label: Label, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, label.size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, label.size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): label.size * 0.06
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label.text, attributes: attributes))
        var x = label.origin.x
        if label.centered {
            x -= CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / 2
        }
        ctx.saveGState()
        // The context is y-down; flip glyphs back upright.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: label.origin.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
