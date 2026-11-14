import CoreGraphics
import Foundation

/// What's selected on a page: ink strokes and objects, by id.
struct PageSelection: Equatable {
    var strokeIDs: Set<UUID> = []
    var objectIDs: Set<UUID> = []

    static let empty = PageSelection()

    var isEmpty: Bool {
        strokeIDs.isEmpty && objectIDs.isEmpty
    }

    var count: Int {
        strokeIDs.count + objectIDs.count
    }
}

/// The selection's frame on screen: a rectangle in its own space and the transform that puts it on the
/// page. It's axis-aligned when the selection is made, except around a single object, where it's the
/// object's own frame (so a rotated object gets a rotated box); it then follows every transform applied
/// to the selection, so it turns with what it holds.
struct SelectionBox: Equatable {
    var rect: CGRect
    var transform: CGAffineTransform = .identity

    /// Corners on the page, clockwise from the top-left.
    var corners: [CGPoint] {
        SelectionHandle.Corner.allCases.map { point(for: $0) }
    }

    var center: CGPoint {
        CGPoint(x: rect.midX, y: rect.midY).applying(transform)
    }

    func point(for corner: SelectionHandle.Corner) -> CGPoint {
        corner.position(in: rect).applying(transform)
    }

    /// The box with `t` applied after its own transform.
    func applying(_ t: CGAffineTransform) -> SelectionBox {
        SelectionBox(rect: rect, transform: transform.concatenating(t))
    }

    /// Whether `point` (page space) is inside the box or within `slop` page points of it.
    func contains(_ point: CGPoint, slop: CGFloat) -> Bool {
        let det = transform.a * transform.d - transform.b * transform.c
        guard abs(det) > 1e-12 else { return false }
        let local = point.applying(transform.inverted())
        // Distances on the page, measured in the box's own space along each axis.
        let sx = max(hypot(transform.a, transform.b), 1e-6), sy = max(hypot(transform.c, transform.d), 1e-6)
        return rect.insetBy(dx: -slop / sx, dy: -slop / sy).contains(local)
    }

    /// The page direction from the box's centre to its top edge, unit length: where the rotate handle goes.
    var up: CGPoint {
        let top = CGPoint(x: rect.midX, y: rect.minY).applying(transform)
        let v = top - center
        let length = hypot(v.x, v.y)
        guard length > 1e-9 else {
            let u = CGPoint(x: 0, y: -1).applyingVector(transform)
            let l = max(hypot(u.x, u.y), 1e-9)
            return CGPoint(x: u.x / l, y: u.y / l)
        }
        return CGPoint(x: v.x / length, y: v.y / length)
    }
}

/// The part of the selection box a touch grabs.
enum SelectionHandle: Equatable {
    /// Inside the box: drag to move.
    case move
    /// A corner knob: drag to resize, keeping the opposite corner where it is.
    case corner(Corner)
    /// The knob above the box: drag to rotate about the box's centre.
    case rotate

    enum Corner: CaseIterable, Equatable {
        case topLeft, topRight, bottomRight, bottomLeft

        var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomRight: .topLeft
            case .bottomLeft: .topRight
            }
        }

        func position(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            }
        }
    }
}

/// Selection, hit-testing and the selection handles' transforms: pure geometry on page-space values,
/// shared by the lasso, tap-to-select and circle-to-select.
enum SelectionGeometry {
    /// A stroke as selection sees it: its id, centerline and the bounds of its drawn ink.
    struct StrokeShape {
        let id: UUID
        let path: [CGPoint]
        let bounds: CGRect
        /// Half the stroke's widest nib, so a tap on the ink's edge still hits it.
        let radius: CGFloat
    }

    /// Everything the lasso region touches: strokes any part of whose centerline is inside it (see
    /// `LassoGeometry.stroke(_:touches:polygonBounds:)`), and objects whose outline touches it or that
    /// hold it entirely. Objects of unknown kinds are never selected.
    static func select(in polygon: [CGPoint], strokes: [StrokeShape], objects: [any PageObject]) -> PageSelection {
        guard polygon.count >= 3 else { return .empty }
        let pb = LassoGeometry.bounds(of: polygon)
        var selection = PageSelection()
        for stroke in strokes where stroke.bounds.intersects(pb) {
            if LassoGeometry.stroke(stroke.path, touches: polygon, polygonBounds: pb) {
                selection.strokeIDs.insert(stroke.id)
            }
        }
        for object in objects where PageObjectKinds.isSelectable(object) && object.bounds.intersects(pb) {
            let outline = object.corners + [object.corners[0]]
            if LassoGeometry.stroke(outline, touches: polygon, polygonBounds: pb) || object.contains(polygon[0]) {
                selection.objectIDs.insert(object.id)
            }
        }
        return selection
    }

    /// The topmost thing under `point`: ink first (it's drawn over every object), newest stroke first,
    /// then objects from the top of the stack down. `tolerance` is in page points.
    static func hitTest(_ point: CGPoint, tolerance: CGFloat, strokes: [StrokeShape],
                        objects: [any PageObject]) -> PageSelection? {
        for stroke in strokes.reversed() {
            let reach = tolerance + stroke.radius
            guard stroke.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { continue }
            if distance(from: point, toPolyline: stroke.path) <= reach {
                return PageSelection(strokeIDs: [stroke.id])
            }
        }
        for object in objects.reversed() where PageObjectKinds.isSelectable(object) {
            if object.contains(point, tolerance: tolerance) {
                return PageSelection(objectIDs: [object.id])
            }
        }
        return nil
    }

    static func distance(from p: CGPoint, toPolyline path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .infinity }
        var best = p.distance(to: first)
        for i in path.indices.dropFirst() {
            let a = path[i - 1], b = path[i]
            let ab = b - a
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 > 0 ? min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2, 0), 1) : 0
            best = min(best, p.distance(to: CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)))
        }
        return best
    }

    /// The box drawn around a fresh selection: a single object's own frame and transform, or else the
    /// axis-aligned bounds of everything selected. Nil when nothing is.
    static func box(strokeBounds: [CGRect], objects: [any PageObject]) -> SelectionBox? {
        if strokeBounds.isEmpty, objects.count == 1, let object = objects.first {
            return SelectionBox(rect: object.frame, transform: object.transform)
        }
        var r = CGRect.null
        for b in strokeBounds {
            r = r.union(b)
        }
        for object in objects {
            r = r.union(object.bounds)
        }
        return r.isNull ? nil : SelectionBox(rect: r)
    }

    /// The handle under `point` (page space): the rotate knob, then a corner, then the inside of the box.
    /// `reach` is how far from a knob still grabs it and `rotateDistance` how far the rotate knob sits
    /// above the box's top edge, both in page points.
    static func handle(at point: CGPoint, box: SelectionBox, reach: CGFloat, rotateDistance: CGFloat) -> SelectionHandle? {
        if point.distance(to: rotateHandle(of: box, distance: rotateDistance)) <= reach {
            return .rotate
        }
        // The nearest corner in reach, so corners of a small box don't shadow each other.
        let corners = SelectionHandle.Corner.allCases
            .map { ($0, point.distance(to: box.point(for: $0))) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }
        if let (corner, _) = corners {
            return .corner(corner)
        }
        return box.contains(point, slop: reach / 2) ? .move : nil
    }

    /// Where the rotate knob is: `distance` page points out from the middle of the box's top edge.
    static func rotateHandle(of box: SelectionBox, distance: CGFloat) -> CGPoint {
        let top = CGPoint(x: box.rect.midX, y: box.rect.minY).applying(box.transform)
        let up = box.up
        return CGPoint(x: top.x + up.x * distance, y: top.y + up.y * distance)
    }

    /// The transform that dragging `handle` of `box` from `start` to `current` (page space) applies to the
    /// selection. Resizing works in the box's own axes and never flips it or makes it smaller than
    /// `minimumSize` page points a side; rotating turns it about its centre.
    static func transform(for handle: SelectionHandle, box: SelectionBox, from start: CGPoint, to current: CGPoint,
                          minimumSize: CGFloat = 4) -> CGAffineTransform {
        switch handle {
        case .move:
            let d = current - start
            return CGAffineTransform(translationX: d.x, y: d.y)
        case .rotate:
            let c = box.center
            let angle = atan2(current.y - c.y, current.x - c.x) - atan2(start.y - c.y, start.x - c.x)
            return CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        case let .corner(corner):
            let det = box.transform.a * box.transform.d - box.transform.b * box.transform.c
            guard abs(det) > 1e-12 else { return .identity }
            let toLocal = box.transform.inverted()
            let anchor = corner.opposite.position(in: box.rect)
            let grabbed = corner.position(in: box.rect)
            // Where the grabbed corner goes: where it was, plus how far the finger moved (in local space).
            let moved = grabbed + (current.applying(toLocal) - start.applying(toLocal))
            func factor(_ to: CGFloat, _ from: CGFloat, _ anchor: CGFloat, axisScale: CGFloat) -> CGFloat {
                let span = from - anchor
                guard abs(span) > 1e-9 else { return 1 }
                let minimum = minimumSize / max(axisScale, 1e-9) / abs(span)
                return max((to - anchor) / span, minimum)
            }
            let axisX = hypot(box.transform.a, box.transform.b), axisY = hypot(box.transform.c, box.transform.d)
            let sx = factor(moved.x, grabbed.x, anchor.x, axisScale: axisX)
            let sy = factor(moved.y, grabbed.y, anchor.y, axisScale: axisY)
            let local = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
            return toLocal.concatenating(local).concatenating(box.transform)
        }
    }
}

// MARK: - Transforming ink

extension Stroke {
    /// The stroke moved, scaled or rotated by `t`: every point mapped through it, the azimuth (and a flat
    /// nib's angle) turned with it, and the brush's widths and taper scaled by its area change, so a
    /// stroke made twice as big is drawn twice as thick. A rigid move leaves the brush exactly as it was.
    func applying(_ t: CGAffineTransform) -> Stroke {
        var copy = self
        let rotation = atan2(t.b, t.a)
        let turns = abs(rotation) > 1e-12
        for i in copy.points.indices {
            copy.points[i].location = points[i].location.applying(t)
            if turns {
                copy.points[i].azimuth = Self.normalized(points[i].azimuth + rotation)
            }
        }
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        if abs(scale - 1) > 1e-9 {
            copy.brush = brush.scaled(by: scale)
        }
        if turns, case let .ellipse(aspect, angle) = copy.brush.tip {
            copy.brush.tip = .ellipse(aspect: aspect, angle: Self.normalized(angle + rotation))
        }
        return copy
    }

    private static func normalized(_ angle: CGFloat) -> CGFloat {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi {
            a -= 2 * .pi
        } else if a < -.pi {
            a += 2 * .pi
        }
        return a
    }
}

extension BrushDescriptor {
    /// The brush drawn `factor` times as large: its widths and taper lengths scaled, then clamped.
    func scaled(by factor: CGFloat) -> BrushDescriptor {
        guard factor.isFinite, factor > 0 else { return self }
        var b = self
        b.size = (size.lowerBound * factor) ... (size.upperBound * factor)
        b.taper.startLength *= factor
        b.taper.endLength *= factor
        return b.clamped()
    }
}

extension CGPoint {
    /// `self` as a vector through `t`'s linear part (no translation).
    func applyingVector(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: x * t.a + y * t.c, y: x * t.b + y * t.d)
    }
}
