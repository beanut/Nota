import CoreGraphics
import Foundation

/// Where a template expects writing to go, in canvas space (points from the page's top-left, y down).
/// The handwriting layout engine (NOT-65) lines generated ink up with these.
public struct TemplateLineMetrics: Equatable, Sendable {
    /// The gap between writing lines, or nil when the page isn't lined.
    public var lineSpacing: CGFloat?
    /// The y of each writing line, top to bottom. Ink sits on these.
    public var baselines: [CGFloat]
    /// The part of the page meant for writing (inside the margins, right of a margin rule or checkbox).
    public var writingArea: CGRect
    /// The pitch of a grid, dot or isometric pattern, or nil.
    public var gridSpacing: CGFloat?
    /// Separate areas to write in, in reading order: Cornell's cues, notes and summary, a planner's days.
    public var regions: [CGRect]
}

public extension PageTemplate {
    /// The template's writing lines and areas on a page of `pageSize`.
    func lineMetrics(on pageSize: PageSize) -> TemplateLineMetrics {
        let page = pageSize.bounds
        let inner = TemplateLayout.inner(self, page: page)
        switch pattern {
        case .blank:
            return TemplateLineMetrics(lineSpacing: nil, baselines: [], writingArea: inner, gridSpacing: nil, regions: [])
        case .ruled:
            let left = marginRule ? margins.left : 0
            let area = CGRect(x: left, y: inner.minY, width: page.width - left - margins.right, height: inner.height)
            return TemplateLineMetrics(lineSpacing: spacing, baselines: TemplateLayout.ruledBaselines(self, page: page),
                                       writingArea: area, gridSpacing: nil, regions: [])
        case .grid, .dots, .isometric:
            let grid = TemplateLayout.grid(self, page: page)
            let rows = TemplateGeometry.steps(from: grid.origin.y, to: inner.maxY, by: spacing,
                                              within: inner.minY ... inner.maxY)
            return TemplateLineMetrics(lineSpacing: pattern == .isometric ? nil : spacing,
                                       baselines: pattern == .isometric ? [] : rows,
                                       writingArea: pattern == .isometric ? page : inner, gridSpacing: spacing, regions: [])
        case .cornell:
            let layout = TemplateLayout.cornell(self, page: page)
            return TemplateLineMetrics(lineSpacing: spacing, baselines: TemplateLayout.cornellBaselines(self, page: page),
                                       writingArea: layout.notes, gridSpacing: nil,
                                       regions: [layout.cues, layout.notes, layout.summary])
        case .musicStaff:
            return TemplateLineMetrics(lineSpacing: nil, baselines: [], writingArea: inner, gridSpacing: nil,
                                       regions: TemplateLayout.staves(self, page: page).compactMap { staff in
                                           guard let top = staff.first, let bottom = staff.last else { return nil }
                                           return CGRect(x: inner.minX, y: top, width: inner.width, height: bottom - top)
                                       })
        case .todo:
            let rows = TemplateLayout.todoRows(self, page: page)
            let left = rows.first?.line.minX ?? inner.minX
            let area = CGRect(x: left, y: inner.minY, width: inner.maxX - left, height: inner.height)
            return TemplateLineMetrics(lineSpacing: spacing, baselines: rows.map(\.line.minY), writingArea: area,
                                       gridSpacing: nil, regions: [])
        case .weeklyPlanner:
            let layout = TemplateLayout.weekly(self, page: page)
            return TemplateLineMetrics(lineSpacing: nil, baselines: [], writingArea: inner, gridSpacing: nil,
                                       regions: [layout.header] + layout.cells)
        case .monthlyPlanner:
            let layout = TemplateLayout.monthly(self, page: page)
            return TemplateLineMetrics(lineSpacing: nil, baselines: [], writingArea: inner, gridSpacing: nil,
                                       regions: [layout.header] + layout.dayCells)
        }
    }
}

/// The measurements each pattern is drawn from, shared by `TemplateGeometry` (drawing) and `lineMetrics`.
enum TemplateLayout {
    static func inner(_ t: PageTemplate, page: CGRect) -> CGRect {
        let m = t.margins
        return CGRect(x: m.left, y: m.top, width: max(0, page.width - m.left - m.right),
                      height: max(0, page.height - m.top - m.bottom))
    }

    /// First line at the top margin, then one every `spacing` down to the bottom margin.
    static func ruledBaselines(_ t: PageTemplate, page: CGRect) -> [CGFloat] {
        let inner = inner(t, page: page)
        return TemplateGeometry.steps(from: inner.minY, to: inner.maxY, by: t.spacing, within: inner.minY ... inner.maxY)
    }

    /// A grid's first line on each axis, placed so the cells are centred in the margins.
    static func grid(_ t: PageTemplate, page: CGRect) -> (origin: CGPoint, spacing: CGFloat) {
        let inner = inner(t, page: page)
        let s = t.spacing
        let x = inner.minX + inner.width.truncatingRemainder(dividingBy: s) / 2
        let y = inner.minY + inner.height.truncatingRemainder(dividingBy: s) / 2
        return (CGPoint(x: x, y: y), s)
    }

    struct Cornell {
        var cues: CGRect
        var notes: CGRect
        var summary: CGRect
    }

    struct Monthly {
        var header: CGRect
        var weekdays: CGRect
        var days: CGRect
        var dayCells: [CGRect]
    }

    /// Cue column (30% of the width) beside the notes, over a summary (the bottom fifth), under the header.
    static func cornell(_ t: PageTemplate, page: CGRect) -> Cornell {
        let inner = inner(t, page: page)
        let summaryTop = inner.maxY - (page.height * 0.2).rounded()
        let cueWidth = (page.width * 0.3).rounded()
        let body = CGRect(x: 0, y: inner.minY, width: page.width, height: summaryTop - inner.minY)
        return Cornell(cues: CGRect(x: 0, y: body.minY, width: cueWidth, height: body.height),
                       notes: CGRect(x: cueWidth, y: body.minY, width: page.width - cueWidth, height: body.height),
                       summary: CGRect(x: 0, y: summaryTop, width: page.width, height: inner.maxY - summaryTop))
    }

    /// Ruled lines under the header in both the notes and the summary, skipping any too close to the
    /// summary's divider.
    static func cornellBaselines(_ t: PageTemplate, page: CGRect) -> [CGFloat] {
        let layout = cornell(t, page: page)
        let notes = TemplateGeometry.steps(from: layout.notes.minY + t.spacing, to: layout.notes.maxY - t.spacing / 2,
                                           by: t.spacing, within: layout.notes.minY ... layout.notes.maxY)
        let summary = TemplateGeometry.steps(from: layout.summary.minY + t.spacing, to: layout.summary.maxY,
                                             by: t.spacing, within: layout.summary.minY ... layout.summary.maxY)
        return notes + summary
    }

    /// Five lines `spacing` apart per staff, staves spread evenly down the page with at least 1.75 staff
    /// heights between them.
    static func staves(_ t: PageTemplate, page: CGRect) -> [[CGFloat]] {
        let inner = inner(t, page: page)
        let height = 4 * t.spacing
        let minGap = 1.75 * height
        let count = Int(((inner.height + minGap) / (height + minGap)).rounded(.down))
        guard count > 0 else { return [] }
        let gap = count > 1 ? (inner.height - CGFloat(count) * height) / CGFloat(count - 1) : 0
        return (0 ..< count).map { i in
            let top = inner.minY + CGFloat(i) * (height + gap)
            return (0 ..< 5).map { top + CGFloat($0) * t.spacing }
        }
    }

    /// One row per `spacing`: a checkbox at the left margin, then a line to write the item on. `line` has
    /// zero height; its `minY` is the baseline.
    static func todoRows(_ t: PageTemplate, page: CGRect) -> [(checkbox: CGRect, line: CGRect)] {
        let inner = inner(t, page: page)
        let box = (t.spacing * 0.45).rounded()
        let lineStart = inner.minX + box + t.spacing * 0.4
        return TemplateGeometry.steps(from: inner.minY + t.spacing, to: inner.maxY, by: t.spacing,
                                      within: inner.minY ... inner.maxY).map { y in
            (CGRect(x: inner.minX, y: y - t.spacing / 2 - box / 2, width: box, height: box),
             CGRect(x: lineStart, y: y, width: inner.maxX - lineStart, height: 0))
        }
    }

    /// A header band, then the week's seven days and a Notes cell in two columns of four.
    static func weekly(_ t: PageTemplate, page: CGRect) -> (header: CGRect, cells: [CGRect]) {
        let inner = inner(t, page: page)
        let header = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: (t.spacing * 2.5).rounded())
        let gap: CGFloat = 6
        let top = header.maxY + gap
        let width = (inner.width - gap) / 2, height = (inner.maxY - top - 3 * gap) / 4
        let cells = (0 ..< 8).map { i in
            CGRect(x: inner.minX + CGFloat(i / 4) * (width + gap), y: top + CGFloat(i % 4) * (height + gap),
                   width: width, height: max(0, height))
        }
        return (header, cells)
    }

    /// A header band, a row of weekday names, then six weeks of seven days.
    static func monthly(_ t: PageTemplate, page: CGRect) -> Monthly {
        let inner = inner(t, page: page)
        let header = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: (t.spacing * 2.5).rounded())
        let weekdays = CGRect(x: inner.minX, y: header.maxY + 4, width: inner.width, height: max(14, t.spacing))
        let days = CGRect(x: inner.minX, y: weekdays.maxY, width: inner.width, height: max(0, inner.maxY - weekdays.maxY))
        let w = days.width / 7, h = days.height / 6
        let cells = (0 ..< 42).map { i in
            CGRect(x: days.minX + CGFloat(i % 7) * w, y: days.minY + CGFloat(i / 7) * h, width: w, height: h)
        }
        return Monthly(header: header, weekdays: weekdays, days: days, dayCells: cells)
    }

    /// The week's day names starting from `calendar`'s first weekday.
    static func weekdayNames(_ calendar: Calendar, short: Bool) -> [String] {
        let symbols = short ? calendar.shortWeekdaySymbols : calendar.weekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = min(max(calendar.firstWeekday - 1, 0), 6)
        return Array(symbols[first...] + symbols[..<first])
    }
}
