import CoreGraphics

/// Where a page's lines of writing are, so the zoom window can follow them: the spacing between ruled
/// lines, where the first one sits and how far across the page handwriting runs. All in page points.
///
/// Derived from the page's template (`init(template:on:)`); pages without ruling use `standard(for:)`.
public struct WritingLines: Equatable, Sendable {
    /// Distance between two baselines.
    public var spacing: CGFloat
    /// The first baseline's distance from the top of the page.
    public var firstBaseline: CGFloat
    /// Where a line of writing starts; the zoom window returns here on a new line.
    public var left: CGFloat
    /// Where a line of writing ends; reaching it moves the zoom window to the next line.
    public var right: CGFloat

    public init(spacing: CGFloat, firstBaseline: CGFloat, left: CGFloat, right: CGFloat) {
        self.spacing = max(spacing, 1)
        self.firstBaseline = firstBaseline
        self.left = left
        self.right = max(right, left + 1)
    }

    /// The lines of `template` on a page of `pageSize`: its ruled lines, or every row of a grid or dots.
    /// Templates without evenly spaced rows (blank, planners, …) get `standard(for:)`.
    public static func lines(for template: PageTemplate, on pageSize: PageSize) -> WritingLines {
        let metrics = template.lineMetrics(on: pageSize)
        let page = pageSize.bounds.size
        guard let spacing = metrics.lineSpacing, let first = metrics.baselines.first else {
            return standard(for: page)
        }
        let area = metrics.writingArea
        return WritingLines(spacing: spacing, firstBaseline: first, left: area.minX + spacing,
                            right: area.maxX - spacing)
    }

    /// Lines for a page without ruling: about 19 to a page width (32 pt on US Letter), the first three
    /// lines down, with a line's height of margin each side.
    public static func standard(for pageSize: CGSize) -> WritingLines {
        let spacing = max(pageSize.width / 19, 12)
        return WritingLines(spacing: spacing, firstBaseline: 3 * spacing,
                            left: spacing, right: pageSize.width - spacing)
    }

    /// Baseline `n`, counting from 0.
    func baseline(_ n: Int) -> CGFloat {
        firstBaseline + CGFloat(n) * spacing
    }

    /// The line whose baseline is nearest `y`; never above the first.
    func line(nearest y: CGFloat) -> Int {
        max(0, Int(((y - firstBaseline) / spacing).rounded()))
    }
}

/// The zoom window's box on the page and how it moves along the lines as you write.
///
/// The box is the part of the page the writing panel magnifies. It has the panel's aspect ratio, so its
/// width sets the magnification, and it rides on a line: the line's baseline sits `baselineFraction` of the
/// way down, leaving room for ascenders above and descenders below.
///
/// When a stroke written in the panel reaches into the box's right-hand `advanceFraction`, the box slides
/// along so that stroke's end is `leadInFraction` from its left edge. Once the box has reached the end of the
/// line, the next stroke into that zone sends it back to the start of the next line.
struct ZoomWindow: Equatable {
    static let baselineFraction: CGFloat = 0.72
    static let advanceFraction: CGFloat = 0.7
    static let leadInFraction: CGFloat = 0.25
    /// Default box height, in line spacings.
    static let defaultHeightInLines: CGFloat = 1.5
    /// The box can be resized between these heights, in line spacings.
    static let heightRangeInLines: ClosedRange<CGFloat> = 1 ... 4

    enum Move: Equatable {
        case stayed, advanced, newLine
    }

    /// The box, in page points.
    private(set) var box: CGRect
    let page: CGRect
    let lines: WritingLines
    /// Width over height of the writing panel, and so of the box.
    let aspect: CGFloat

    /// A box on the page. Given `box`, keeps its left edge, width and line, refitted to `aspect` and the
    /// page; otherwise starts on the first line at the left margin.
    init(page: CGRect, lines: WritingLines, aspect: CGFloat, box previous: CGRect? = nil) {
        self.page = page
        self.lines = lines
        self.aspect = max(aspect, 0.1)
        let width = previous?.width ?? Self.defaultHeightInLines * lines.spacing * self.aspect
        box = CGRect(x: previous?.minX ?? lines.left, y: 0, width: 0, height: 0)
        let line = previous.map { lines.line(nearest: $0.minY + Self.baselineFraction * $0.height) } ?? 0
        place(width: width, minX: box.minX, line: line)
    }

    /// The line the box is on.
    var line: Int {
        lines.line(nearest: box.minY + Self.baselineFraction * box.height)
    }

    /// Strokes reaching past here move the box on.
    var advanceX: CGFloat {
        box.minX + Self.advanceFraction * box.width
    }

    /// False at the start of the first line, where there's nowhere to go back to.
    var canGoBack: Bool {
        line > 0 || box.minX > leftLimit + 0.5
    }

    /// Widths the box can be resized between.
    var widthRange: ClosedRange<CGFloat> {
        let range = Self.heightRangeInLines
        let lower = range.lowerBound * lines.spacing * aspect
        let upper = min(range.upperBound * lines.spacing * aspect, rightLimit - leftLimit)
        return min(lower, upper) ... upper
    }

    private var leftLimit: CGFloat {
        max(page.minX, lines.left)
    }

    private var rightLimit: CGFloat {
        min(page.maxX, lines.right)
    }

    private var isAtLineEnd: Bool {
        box.maxX >= rightLimit - 0.5
    }

    // MARK: Following the writing

    /// A stroke written in the panel ended with these bounds (page points). Moves the box on if the stroke
    /// reached into the advance zone.
    @discardableResult
    mutating func strokeEnded(bounds: CGRect) -> Move {
        guard !bounds.isNull, bounds.maxX > advanceX, bounds.intersects(box) else { return .stayed }
        if isAtLineEnd {
            return newLine() ? .newLine : .stayed
        }
        let minX = bounds.maxX - Self.leadInFraction * box.width
        guard minX > box.minX else { return .stayed }
        place(width: box.width, minX: minX, line: line)
        return .advanced
    }

    /// Moves the box on by most of its width; at the end of the line, to the start of the next one.
    @discardableResult
    mutating func advance() -> Move {
        if isAtLineEnd {
            return newLine() ? .newLine : .stayed
        }
        place(width: box.width, minX: box.minX + (1 - Self.leadInFraction) * box.width, line: line)
        return .advanced
    }

    /// Moves the box back by most of its width; at the start of a line, to the end of the line above.
    @discardableResult
    mutating func back() -> Bool {
        let old = box
        if box.minX <= leftLimit + 0.5 {
            guard line > 0 else { return false }
            place(width: box.width, minX: rightLimit - box.width, line: line - 1)
        } else {
            place(width: box.width, minX: box.minX - (1 - Self.leadInFraction) * box.width, line: line)
        }
        return box != old
    }

    /// Moves the box to the start of the next line, if there's room for it on the page.
    @discardableResult
    mutating func newLine() -> Bool {
        let next = line + 1
        guard lines.baseline(next) + (1 - Self.baselineFraction) * box.height <= page.maxY + 0.5 else { return false }
        place(width: box.width, minX: leftLimit, line: next)
        return true
    }

    // MARK: Moving and resizing by hand

    /// Drags the box's top-left corner to `origin` (page points), kept on the page. Call `snapToLine()` when
    /// the drag ends.
    mutating func move(to origin: CGPoint) {
        box.origin = CGPoint(x: clamped(origin.x, box.width, page.minX, page.maxX),
                             y: clamped(origin.y, box.height, page.minY, page.maxY))
    }

    /// Settles a dragged box onto the nearest line.
    mutating func snapToLine() {
        place(width: box.width, minX: box.minX, line: line)
    }

    /// Resizes the box to `width` (within `widthRange`), keeping its left edge and line.
    mutating func resize(toWidth width: CGFloat) {
        place(width: width, minX: box.minX, line: line)
    }

    // MARK: Layout

    private mutating func place(width: CGFloat, minX: CGFloat, line: Int) {
        let range = widthRange
        let w = min(max(width, range.lowerBound), range.upperBound)
        let h = w / aspect
        let x = clamped(minX, w, leftLimit, rightLimit)
        let y = clamped(lines.baseline(line) - Self.baselineFraction * h, h, page.minY, page.maxY)
        box = CGRect(x: x, y: y, width: w, height: h)
    }

    /// `value` moved so that `[value, value + length]` fits in `[lower, upper]`, or `lower` if it can't.
    private func clamped(_ value: CGFloat, _ length: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper - length))
    }
}
