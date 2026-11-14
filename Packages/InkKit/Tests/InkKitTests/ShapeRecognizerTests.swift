import CoreGraphics
import Foundation
@testable import InkKit
import Testing

/// A small deterministic generator, so the "hand-drawn" wobble is the same on every run.
private struct Wobble {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10000) / 10000 * 2 - 1 // -1…1
    }
}

/// `path` sampled every ~2 points with a slow wobble of up to `amount` points across it, like a hand.
private func handDrawn(_ path: [CGPoint], amount: CGFloat, seed: UInt64 = 1) -> [CGPoint] {
    var rng = Wobble(seed: seed)
    let dense = ShapeRecognizer.resample(path, count: max(Int(ShapeRecognizer.pathLength(path) / 2), 8))
    var drift = CGPoint.zero
    return dense.map { p in
        drift = CGPoint(x: drift.x * 0.9 + rng.next() * amount * 0.3, y: drift.y * 0.9 + rng.next() * amount * 0.3)
        let limit = amount
        drift = CGPoint(x: min(max(drift.x, -limit), limit), y: min(max(drift.y, -limit), limit))
        return CGPoint(x: p.x + drift.x, y: p.y + drift.y)
    }
}

private func ellipsePath(center c: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat = 0, turns: CGFloat = 1,
                         start: CGFloat = -.pi / 2) -> [CGPoint] {
    let n = 120
    return (0 ... n).map { i in
        let t = start + CGFloat(i) / CGFloat(n) * 2 * .pi * turns
        let x = rx * cos(t), y = ry * sin(t)
        return CGPoint(x: c.x + x * cos(rotation) - y * sin(rotation), y: c.y + x * sin(rotation) + y * cos(rotation))
    }
}

private func polygonPath(_ corners: [CGPoint], overshoot: CGFloat = 0) -> [CGPoint] {
    var path = corners + [corners[0]]
    if overshoot > 0 {
        let a = corners[0], b = corners[1]
        let d = a.distance(to: b)
        path.append(CGPoint(x: a.x + (b.x - a.x) * overshoot / d, y: a.y + (b.y - a.y) * overshoot / d))
    }
    return path
}

private func rotated(_ pts: [CGPoint], by angle: CGFloat, about c: CGPoint) -> [CGPoint] {
    pts.map { p in
        let x = p.x - c.x, y = p.y - c.y
        return CGPoint(x: c.x + x * cos(angle) - y * sin(angle), y: c.y + x * sin(angle) + y * cos(angle))
    }
}

private func near(_ a: CGPoint, _ b: CGPoint, within e: CGFloat) -> Bool {
    a.distance(to: b) <= e
}

@Suite("Shape recognition")
struct ShapeRecognizerTests {
    @Test func aWobblyStrokeIsALineSnappedToTheAxis() throws {
        let stroke = handDrawn([CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 212)], amount: 2)
        let shape = try #require(ShapeRecognizer.recognize(stroke))
        guard case let .points(kind, points) = shape else {
            Issue.record("expected points, got \(shape)")
            return
        }
        #expect(kind == .line)
        // 2.3° off horizontal: straightened.
        #expect(abs(points[1].y - points[0].y) < 1e-6)
        #expect(near(points[0], stroke[0], within: 0.01))
    }

    @Test func aSteepLineKeepsItsAngle() {
        let stroke = handDrawn([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 230)], amount: 1.5)
        guard case let .points(.line, points)? = ShapeRecognizer.recognize(stroke) else {
            Issue.record("not a line")
            return
        }
        let angle = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
        #expect(abs(angle - atan2(130, 200)) < 0.05) // 33°: nowhere near a multiple of 45°
    }

    @Test func aShaftWithBarbsIsAnArrow() throws {
        let tail = CGPoint(x: 100, y: 300), tip = CGPoint(x: 400, y: 300)
        let path = [tail, tip, CGPoint(x: 360, y: 275), tip, CGPoint(x: 362, y: 328)]
        let shape = try #require(ShapeRecognizer.recognize(handDrawn(path, amount: 1.5)))
        guard case let .points(kind, points) = shape else {
            Issue.record("expected points")
            return
        }
        #expect(kind == .arrow)
        #expect(near(points[0], tail, within: 6))
        #expect(near(points[1], tip, within: 6))
    }

    @Test func aHookAtTheEndIsAnArrowToo() {
        let tail = CGPoint(x: 100, y: 100), tip = CGPoint(x: 300, y: 300)
        let path = [tail, tip, CGPoint(x: 260, y: 295)]
        #expect(ShapeRecognizer.recognize(handDrawn(path, amount: 1))?.kind == .arrow)
    }

    @Test func aWobblyCircleIsACircle() {
        let stroke = handDrawn(ellipsePath(center: CGPoint(x: 300, y: 300), rx: 100, ry: 96, turns: 1.08), amount: 3)
        guard case let .framed(kind, center, size, rotation)? = ShapeRecognizer.recognize(stroke) else {
            Issue.record("not framed")
            return
        }
        #expect(kind == .ellipse)
        #expect(size.width == size.height)
        #expect(rotation == 0)
        #expect(near(center, CGPoint(x: 300, y: 300), within: 8))
        #expect(abs(size.width - 196) < 14)
    }

    @Test func aTiltedEllipseKeepsItsTilt() {
        let stroke = handDrawn(ellipsePath(center: CGPoint(x: 300, y: 300), rx: 160, ry: 70, rotation: 0.5), amount: 2.5,
                               seed: 7)
        guard case let .framed(kind, _, size, rotation)? = ShapeRecognizer.recognize(stroke) else {
            Issue.record("not framed")
            return
        }
        #expect(kind == .ellipse)
        #expect(abs(rotation - 0.5) < 0.08)
        #expect(abs(size.width - 320) < 20)
        #expect(abs(size.height - 140) < 16)
    }

    @Test func anUprightishRectangleStandsUpright() {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 260), CGPoint(x: 100, y: 260)]
        let stroke = handDrawn(polygonPath(rotated(corners, by: 0.07, about: CGPoint(x: 250, y: 180)), overshoot: 20),
                               amount: 2.5, seed: 3)
        guard case let .framed(kind, center, size, rotation)? = ShapeRecognizer.recognize(stroke) else {
            Issue.record("not framed: \(String(describing: ShapeRecognizer.recognize(stroke)))")
            return
        }
        #expect(kind == .rectangle)
        #expect(rotation == 0) // 4° off: stood upright
        #expect(near(center, CGPoint(x: 250, y: 180), within: 6))
        #expect(abs(size.width - 300) < 16)
        #expect(abs(size.height - 160) < 16)
    }

    @Test func aTurnedSquareStaysTurnedAndSquare() {
        let c = CGPoint(x: 300, y: 300)
        let corners = rotated([CGPoint(x: 200, y: 200), CGPoint(x: 400, y: 200), CGPoint(x: 400, y: 395),
                               CGPoint(x: 200, y: 395)], by: 0.4, about: c)
        let stroke = handDrawn(polygonPath(corners), amount: 2, seed: 11)
        guard case let .framed(kind, _, size, rotation)? = ShapeRecognizer.recognize(stroke) else {
            Issue.record("not framed")
            return
        }
        #expect(kind == .rectangle)
        #expect(size.width == size.height)
        #expect(abs(rotation - 0.4) < 0.06)
    }

    @Test func threeCornersMakeATriangle() {
        let corners = [CGPoint(x: 300, y: 100), CGPoint(x: 450, y: 350), CGPoint(x: 140, y: 340)]
        let stroke = handDrawn(polygonPath(corners, overshoot: 15), amount: 2.5, seed: 5)
        guard case let .points(kind, points)? = ShapeRecognizer.recognize(stroke) else {
            Issue.record("not points")
            return
        }
        #expect(kind == .triangle)
        for corner in corners {
            #expect(points.contains { near($0, corner, within: 12) })
        }
    }

    @Test func fiveCornersMakeAPentagon() {
        let c = CGPoint(x: 300, y: 300)
        let corners = (0 ..< 5).map { i -> CGPoint in
            let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 5
            return CGPoint(x: c.x + 150 * cos(a), y: c.y + 150 * sin(a))
        }
        let stroke = handDrawn(polygonPath(corners), amount: 1.5, seed: 9)
        guard case let .points(kind, points)? = ShapeRecognizer.recognize(stroke) else {
            Issue.record("not points: \(String(describing: ShapeRecognizer.recognize(stroke)))")
            return
        }
        #expect(kind == .polygon)
        #expect(points.count == 5)
    }

    @Test func aSkewedQuadrilateralIsAPolygon() {
        let corners = [CGPoint(x: 150, y: 100), CGPoint(x: 400, y: 120), CGPoint(x: 480, y: 330), CGPoint(x: 100, y: 300)]
        let shape = ShapeRecognizer.recognize(handDrawn(polygonPath(corners), amount: 1.5, seed: 4))
        #expect(shape?.kind == .polygon)
    }

    @Test func aSmoothArcIsACurve() {
        let arc = (0 ... 60).map { i -> CGPoint in
            let t = CGFloat(i) / 60 * .pi
            return CGPoint(x: 200 + 150 * cos(.pi - t), y: 300 - 90 * sin(t))
        }
        guard case let .points(kind, points)? = ShapeRecognizer.recognize(handDrawn(arc, amount: 1)) else {
            Issue.record("not points")
            return
        }
        #expect(kind == .curve)
        #expect(points.count >= 3)
    }

    @Test func handwritingIsLeftAsInk() {
        // A zigzag "w" with sharp corners: not a shape unless the shape tool asks for a curve.
        let w = [CGPoint(x: 100, y: 100), CGPoint(x: 130, y: 200), CGPoint(x: 160, y: 120), CGPoint(x: 190, y: 200),
                 CGPoint(x: 220, y: 100)]
        #expect(ShapeRecognizer.recognize(w) == nil)
        var options = ShapeRecognizer.Options()
        options.fallbackToCurve = true
        #expect(ShapeRecognizer.recognize(w, options: options)?.kind == .curve)
    }

    @Test func tinyStrokesAreNotShapes() {
        let options = ShapeRecognizer.Options(minimumSize: 30)
        #expect(ShapeRecognizer.recognize([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], options: options) == nil)
        #expect(ShapeRecognizer.recognize([CGPoint(x: 5, y: 5)]) == nil)
    }

    @Test func endsSnapToOtherShapes() {
        var options = ShapeRecognizer.Options()
        options.anchors = [CGPoint(x: 405, y: 207)]
        options.snapDistance = 10
        let stroke = handDrawn([CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 203)], amount: 1)
        guard case let .points(.line, points)? = ShapeRecognizer.recognize(stroke, options: options) else {
            Issue.record("not a line")
            return
        }
        #expect(points[1] == CGPoint(x: 405, y: 207)) // on the anchor, not straightened off it
    }

    /// The same shapes with forty different wobbles each: recognition shouldn't hinge on one lucky stroke.
    @Test(arguments: 1 ... 40 as ClosedRange<UInt64>)
    func commonShapesAreRecognisedAcrossWobbles(seed: UInt64) {
        let c = CGPoint(x: 300, y: 300)
        let circle = handDrawn(ellipsePath(center: c, rx: 110, ry: 104, turns: 1.05), amount: 3, seed: seed)
        #expect(ShapeRecognizer.recognize(circle)?.kind == .ellipse)
        let ellipse = handDrawn(ellipsePath(center: c, rx: 170, ry: 80, rotation: 0.3), amount: 3, seed: seed)
        #expect(ShapeRecognizer.recognize(ellipse)?.kind == .ellipse)
        let rect = handDrawn(polygonPath([CGPoint(x: 100, y: 100), CGPoint(x: 420, y: 100), CGPoint(x: 420, y: 300),
                                          CGPoint(x: 100, y: 300)], overshoot: 12), amount: 3, seed: seed)
        #expect(ShapeRecognizer.recognize(rect)?.kind == .rectangle)
        let triangle = handDrawn(polygonPath([CGPoint(x: 300, y: 100), CGPoint(x: 470, y: 380), CGPoint(x: 120, y: 360)]),
                                 amount: 3, seed: seed)
        #expect(ShapeRecognizer.recognize(triangle)?.kind == .triangle)
        let line = handDrawn([CGPoint(x: 100, y: 100), CGPoint(x: 420, y: 330)], amount: 2.5, seed: seed)
        #expect(ShapeRecognizer.recognize(line)?.kind == .line)
        let arrow = handDrawn([CGPoint(x: 100, y: 400), CGPoint(x: 400, y: 380), CGPoint(x: 365, y: 352),
                               CGPoint(x: 400, y: 380), CGPoint(x: 370, y: 412)], amount: 1.5, seed: seed)
        #expect(ShapeRecognizer.recognize(arrow)?.kind == .arrow)
    }

    @Test func recognisedShapesBecomeObjects() {
        let style = ShapeStyle(color: PenColor(rgb: 0x0A5BD6), lineWidth: 3)
        let framed = ShapeRecognizer.Shape.framed(.rectangle, center: CGPoint(x: 200, y: 200),
                                                  size: CGSize(width: 100, height: 50), rotation: .pi / 6)
        let object = framed.object(style: style)
        #expect(object.shape == .rectangle)
        #expect(object.frame == CGRect(x: 150, y: 175, width: 100, height: 50))
        #expect(abs(atan2(object.transform.b, object.transform.a) - .pi / 6) < 1e-9)
        let center = CGPoint(x: object.frame.midX, y: object.frame.midY).applying(object.transform)
        #expect(near(center, CGPoint(x: 200, y: 200), within: 1e-9))
    }
}
