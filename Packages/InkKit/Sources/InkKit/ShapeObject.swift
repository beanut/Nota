import CoreGraphics
import Foundation

/// A drawn shape on the page: a line, an arrow, a rectangle, an ellipse, a triangle, a polygon or a curve.
/// Made by the shape tool, or by drawing with a pen or pencil and holding the Pencil still at the end
/// (`ShapeRecognizer`).
///
/// **Geometry.** A rectangle or an ellipse is its `frame` (an ellipse fills it); a rotated one keeps an
/// axis-aligned frame and turns with its `transform`. Every other kind is its `points`, in the object's
/// own space, and its `frame` is always their bounds: a line or an arrow runs from `points[0]` to
/// `points[1]` (the head is at `points[1]`), a triangle or polygon joins its points into a closed outline,
/// and a curve passes smoothly through its points in order. Those points are the shape's handles: each
/// can be dragged to reshape it (`movingHandle(_:to:)`); a rectangle or ellipse reshapes with the
/// selection box's corners.
///
/// **Style.** The outline is `strokeColor` at `lineWidth` page points, solid, dashed or dotted. The width
/// scales with the shape when it's resized (by the square root of the area change, like ink), but never
/// stretches unevenly. Closed kinds can have a `fill`, drawn at `fillOpacity` under the outline.
///
/// File kind `"shape"`; its own fields are `shape`, `points` (`[[x, y], …]`), `strokeColor`, `lineWidth`,
/// `lineStyle`, `fill` and `fillOpacity`. Reading is lenient: an unknown `shape` or points that don't fit
/// it read as a rectangle in the same frame, and a bad colour or width takes the default, so a shape
/// is never lost.
public struct ShapeObject: PageObject, Equatable {
    public static let kind = "shape"

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case line, arrow, rectangle, ellipse, triangle, polygon, curve

        /// Whether the shape is its points (and they're its handles), rather than its frame.
        public var isPointBased: Bool {
            switch self {
            case .rectangle, .ellipse: false
            default: true
            }
        }

        /// Whether the outline is closed, so it can be filled.
        public var isClosed: Bool {
            switch self {
            case .rectangle, .ellipse, .triangle, .polygon: true
            case .line, .arrow, .curve: false
            }
        }

        /// A line or an arrow: two ends and nothing between.
        public var isLinear: Bool {
            self == .line || self == .arrow
        }

        /// Whether `count` points make a shape of this kind.
        func accepts(pointCount count: Int) -> Bool {
            switch self {
            case .rectangle, .ellipse: count == 0
            case .line, .arrow: count == 2
            case .triangle: count == 3
            case .polygon: count >= 3
            case .curve: count >= 2
            }
        }
    }

    public enum LineStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case solid, dashed, dotted

        public var id: String {
            rawValue
        }
    }

    public let id: UUID
    public var frame: CGRect
    public var transform: CGAffineTransform
    public var zIndex: Int
    public private(set) var shape: Kind
    /// The vertices of a point-based kind, in the object's own space; empty for a rectangle or ellipse.
    public private(set) var points: [CGPoint]
    public var strokeColor: PenColor
    /// Page points at the shape's own scale.
    public var lineWidth: CGFloat
    public var lineStyle: LineStyle
    /// Fills a closed shape; ignored for lines, arrows and curves.
    public var fill: PenColor?
    public var fillOpacity: CGFloat

    public static let defaultFillOpacity: CGFloat = 0.3
    static let defaultColor = PenColor(rgb: 0x1C1C1E)

    /// A rectangle or ellipse filling `frame`.
    public init(id: UUID = UUID(), _ shape: Kind, frame: CGRect, transform: CGAffineTransform = .identity,
                zIndex: Int = 0, style: ShapeStyle) {
        precondition(!shape.isPointBased, "\(shape) is made from points")
        self.init(id: id, shape: shape, frame: frame, points: [], transform: transform, zIndex: zIndex, style: style)
    }

    /// A line, arrow, triangle, polygon or curve through `points` (its own space); its frame is their bounds.
    public init(id: UUID = UUID(), _ shape: Kind, points: [CGPoint], transform: CGAffineTransform = .identity,
                zIndex: Int = 0, style: ShapeStyle) {
        precondition(shape.isPointBased && shape.accepts(pointCount: points.count), "\(points.count) points for a \(shape)")
        self.init(id: id, shape: shape, frame: Self.bounds(of: points), points: points, transform: transform,
                  zIndex: zIndex, style: style)
    }

    private init(id: UUID, shape: Kind, frame: CGRect, points: [CGPoint], transform: CGAffineTransform,
                 zIndex: Int, style: ShapeStyle) {
        self.id = id
        self.frame = frame
        self.transform = transform
        self.zIndex = zIndex
        self.shape = shape
        self.points = points
        strokeColor = style.color
        lineWidth = style.lineWidth
        lineStyle = style.lineStyle
        fill = style.fill
        fillOpacity = style.fillOpacity
    }

    /// The shape's colours, width and line style.
    public var style: ShapeStyle {
        get {
            ShapeStyle(color: strokeColor, lineWidth: lineWidth, lineStyle: lineStyle, fill: fill, fillOpacity: fillOpacity)
        }
        set {
            strokeColor = newValue.color
            lineWidth = newValue.lineWidth
            lineStyle = newValue.lineStyle
            fill = newValue.fill
            fillOpacity = newValue.fillOpacity
        }
    }

    // MARK: Handles

    /// The draggable handles on the page: a point-based shape's points; none for a rectangle or ellipse,
    /// which reshape with the selection box.
    public var handles: [CGPoint] {
        points.map { $0.applying(transform) }
    }

    /// The shape with handle `index` moved to `pagePoint`; its frame follows its points.
    public func movingHandle(_ index: Int, to pagePoint: CGPoint) -> ShapeObject {
        guard points.indices.contains(index) else { return self }
        let det = transform.a * transform.d - transform.b * transform.c
        guard abs(det) > 1e-12 else { return self }
        var copy = self
        copy.points[index] = pagePoint.applying(transform.inverted())
        copy.frame = Self.bounds(of: copy.points)
        return copy
    }

    /// Points other shapes snap to (page space): ends and corners, edge midpoints and the centre.
    public var snapAnchors: [CGPoint] {
        let local: [CGPoint]
        let f = frame
        switch shape {
        case .rectangle:
            local = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.maxX, y: f.maxY),
                     CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.midY),
                     CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.minX, y: f.midY), CGPoint(x: f.midX, y: f.midY)]
        case .ellipse:
            local = [CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.midY), CGPoint(x: f.midX, y: f.maxY),
                     CGPoint(x: f.minX, y: f.midY), CGPoint(x: f.midX, y: f.midY)]
        case .triangle, .polygon:
            let mids = points.indices.map { i in
                let a = points[i], b = points[(i + 1) % points.count]
                return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            local = points + mids
        case .line, .arrow, .curve:
            local = [points.first, points.last].compactMap { $0 }
        }
        return local.map { $0.applying(transform) }
    }

    // MARK: Drawing

    /// The outline in the object's own space.
    func outline() -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .rectangle:
            path.addRect(frame)
        case .ellipse:
            path.addEllipse(in: frame)
        case .line, .arrow:
            path.addLines(between: points)
        case .triangle, .polygon:
            path.addLines(between: points)
            path.closeSubpath()
        case .curve:
            Self.addCurve(through: points, to: path)
        }
        return path
    }

    /// The width the outline is drawn at on the page: `lineWidth` scaled with the shape's area.
    var drawnLineWidth: CGFloat {
        let det = abs(transform.a * transform.d - transform.b * transform.c)
        return max(lineWidth * sqrt(det), 0.1)
    }

    public func draw(in ctx: CGContext) {
        let det = transform.a * transform.d - transform.b * transform.c
        guard abs(det) > 1e-12 else { return }
        // Stroke in page space, so the line keeps one width however the shape has been stretched.
        var t = transform
        guard let path = outline().copy(using: &t) else { return }
        let width = drawnLineWidth
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(transform.inverted())
        if shape.isClosed, let fill {
            ctx.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue,
                                     alpha: min(max(fillOpacity, 0), 1)))
            ctx.addPath(path)
            ctx.fillPath()
        }
        let ink = CGColor(srgbRed: strokeColor.red, green: strokeColor.green, blue: strokeColor.blue, alpha: 1)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        switch lineStyle {
        case .solid: break
        case .dashed: ctx.setLineDash(phase: 0, lengths: [width * 3, width * 2.5])
        case .dotted: ctx.setLineDash(phase: 0, lengths: [0, width * 2.2])
        }
        ctx.addPath(path)
        ctx.strokePath()
        if shape == .arrow, let head = arrowHead(width: width) {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.addLines(between: head)
            ctx.strokePath()
        }
    }

    /// The arrowhead's open chevron on the page: one barb, the tip, the other barb.
    func arrowHead(width: CGFloat) -> [CGPoint]? {
        guard shape == .arrow, points.count == 2 else { return nil }
        let from = points[0].applying(transform), tip = points[1].applying(transform)
        let length = from.distance(to: tip)
        guard length > 1e-6 else { return nil }
        let barb = min(max(12, width * 4.5), length * 0.6)
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let spread: CGFloat = .pi / 7
        func end(_ a: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - barb * cos(a), y: tip.y - barb * sin(a))
        }
        return [end(angle + spread), tip, end(angle - spread)]
    }

    /// A Catmull-Rom spline through `points`, as cubic Béziers.
    static func addCurve(through points: [CGPoint], to path: CGMutablePath) {
        guard let first = points.first else { return }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLines(between: points)
            return
        }
        for i in 0 ..< points.count - 1 {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var r = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() {
            r = r.union(CGRect(origin: p, size: .zero))
        }
        return r
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case shape, points, strokeColor, lineWidth, lineStyle, fill, fillOpacity
    }

    public init(from decoder: Decoder) throws {
        let placement = try PageObjectPlacement(from: decoder)
        id = placement.id
        transform = placement.transform
        zIndex = placement.zIndex
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decodeIfPresent(Kind.self, forKey: .shape)) ?? .rectangle
        let pairs = (try? c.decodeIfPresent([[Double]].self, forKey: .points)) ?? []
        let read = pairs.compactMap { pair -> CGPoint? in
            guard pair.count == 2, pair.allSatisfy(\.isFinite) else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
        if kind.isPointBased, read.count == pairs.count, kind.accepts(pointCount: read.count) {
            shape = kind
            points = read
            frame = Self.bounds(of: read)
        } else {
            // A kind this version doesn't draw, or points that don't make it: keep the shape as its frame.
            shape = kind.isPointBased ? .rectangle : kind
            points = []
            frame = placement.frame
        }
        strokeColor = (try? c.decodeIfPresent(PenColor.self, forKey: .strokeColor)) ?? Self.defaultColor
        let width = (try? c.decodeIfPresent(Double.self, forKey: .lineWidth)) ?? 2
        lineWidth = width.isFinite ? CGFloat(min(max(width, 0.1), 200)) : 2
        lineStyle = (try? c.decodeIfPresent(LineStyle.self, forKey: .lineStyle)) ?? .solid
        fill = try? c.decodeIfPresent(PenColor.self, forKey: .fill)
        let opacity = (try? c.decodeIfPresent(Double.self, forKey: .fillOpacity)) ?? Double(Self.defaultFillOpacity)
        fillOpacity = opacity.isFinite ? CGFloat(min(max(opacity, 0), 1)) : Self.defaultFillOpacity
    }

    public func encode(to encoder: Encoder) throws {
        try PageObjectPlacement(of: self).encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape, forKey: .shape)
        if !points.isEmpty {
            try c.encode(points.map { [Double($0.x), Double($0.y)] }, forKey: .points)
        }
        try c.encode(strokeColor, forKey: .strokeColor)
        try c.encode(Double(lineWidth), forKey: .lineWidth)
        try c.encode(lineStyle, forKey: .lineStyle)
        try c.encodeIfPresent(fill, forKey: .fill)
        try c.encode(Double(fillOpacity), forKey: .fillOpacity)
    }
}

/// How a shape is drawn: outline colour and width, solid, dashed or dotted, and an optional fill.
public struct ShapeStyle: Equatable, Sendable {
    public var color: PenColor
    public var lineWidth: CGFloat
    public var lineStyle: ShapeObject.LineStyle
    public var fill: PenColor?
    public var fillOpacity: CGFloat

    public init(color: PenColor, lineWidth: CGFloat, lineStyle: ShapeObject.LineStyle = .solid, fill: PenColor? = nil,
                fillOpacity: CGFloat = ShapeObject.defaultFillOpacity) {
        self.color = color
        self.lineWidth = lineWidth
        self.lineStyle = lineStyle
        self.fill = fill
        self.fillOpacity = fillOpacity
    }
}
