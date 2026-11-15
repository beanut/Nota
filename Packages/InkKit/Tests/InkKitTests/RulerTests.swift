import CoreGraphics
import Foundation
@testable import InkKit
import Testing

private func close(_ a: CGPoint, _ b: CGPoint, within e: CGFloat = 1e-6) -> Bool {
    abs(a.x - b.x) <= e && abs(a.y - b.y) <= e
}

@Suite("Ruler: snapping, length and angle")
struct RulerTests {
    /// Level, centred at (500, 500): its edges are y = 456 (top) and y = 544 (bottom).
    let level = Ruler(center: CGPoint(x: 500, y: 500), angle: 0)

    @Test func aStrokeStartingByAnEdgeSnapsToThatEdge() throws {
        let below = try #require(level.guide(at: CGPoint(x: 300, y: 560)))
        #expect(close(below.project(CGPoint(x: 400, y: 590)), CGPoint(x: 400, y: 544)))
        let above = try #require(level.guide(at: CGPoint(x: 300, y: 440)))
        #expect(close(above.project(CGPoint(x: 900, y: 430)), CGPoint(x: 900, y: 456)))
        // On the body, the nearer edge.
        let onBody = try #require(level.guide(at: CGPoint(x: 300, y: 530)))
        #expect(close(onBody.project(CGPoint(x: 0, y: 500)), CGPoint(x: 0, y: 544)))
    }

    @Test func aStrokeStartingAwayFromTheRulerDoesntSnap() {
        #expect(level.guide(at: CGPoint(x: 300, y: 544 + Ruler.snapDistance + 1)) == nil)
        #expect(level.guide(at: CGPoint(x: 300, y: 100)) == nil)
        #expect(level.guide(at: CGPoint(x: 500 + Ruler.length / 2 + Ruler.snapDistance + 1, y: 550)) == nil)
    }

    @Test func aTurnedRulerGuidesAlongItsAngle() throws {
        let turned = Ruler(center: CGPoint(x: 500, y: 500), angle: .pi / 4)
        // Just past the edge on the normal side.
        let start = turned.point(along: 100, across: Ruler.width / 2 + 10)
        let guide = try #require(turned.guide(at: start))
        let a = guide.project(turned.point(along: -200, across: 70))
        let b = guide.project(turned.point(along: 300, across: 20))
        #expect(close(a, turned.point(along: -200, across: Ruler.width / 2), within: 1e-6))
        #expect(close(b, turned.point(along: 300, across: Ruler.width / 2), within: 1e-6))
        // Every projected point is on one line at 45°.
        #expect(abs((b.y - a.y) / (b.x - a.x) - 1) < 1e-9)
    }

    @Test func aGuideCarriedToThePageStillProjectsOntoTheSameLine() throws {
        let view = ViewTransform(scale: 1.5, offset: CGPoint(x: 40, y: -60))
        let guide = try #require(level.guide(at: CGPoint(x: 300, y: 560)))
        let onPage = guide.mapped(view.toCanvas)
        let p = onPage.project(view.toCanvas(CGPoint(x: 420, y: 600)))
        #expect(close(view.toView(p), CGPoint(x: 420, y: 544), within: 1e-9))
        let arc = RulerGuide.arc(center: CGPoint(x: 100, y: 100), radius: 150).mapped(view.toCanvas)
        guard case let .arc(_, radius) = arc else { return #expect(Bool(false)) }
        #expect(abs(radius - 100) < 1e-9)
    }

    @Test func theProtractorGuidesAlongItsArcAndBaseline() throws {
        let protractor = Ruler(center: CGPoint(x: 500, y: 500), angle: 0, mode: .protractor)
        let r = Ruler.protractorRadius
        let arc = try #require(protractor.guide(at: CGPoint(x: 500, y: 500 - r - 10)))
        let p = arc.project(CGPoint(x: 700, y: 300))
        #expect(abs(p.distance(to: CGPoint(x: 500, y: 500)) - r) < 1e-9)
        let base = try #require(protractor.guide(at: CGPoint(x: 450, y: 510)))
        #expect(close(base.project(CGPoint(x: 420, y: 530)), CGPoint(x: 420, y: 500)))
        #expect(protractor.guide(at: CGPoint(x: 500, y: 400)) == nil) // the middle of the disc
        #expect(protractor.contains(CGPoint(x: 500, y: 400)))
        #expect(!protractor.contains(CGPoint(x: 500, y: 600)))
    }

    @Test func aStrokeAlongAnEdgeMeasuresItsLengthInCentimetres() {
        var measurement = RulerMeasurement(guide: .line(origin: .zero, direction: CGPoint(x: 1, y: 0)))
        measurement.advance(to: CGPoint(x: 10, y: 4))
        measurement.advance(to: CGPoint(x: 80, y: -3))
        measurement.advance(to: CGPoint(x: 10 + 72 / 2.54 * 5, y: 9))
        #expect(abs(measurement.length - 72 / 2.54 * 5) < 1e-9) // 5 cm in page points
        #expect(measurement.readout == "5.0 cm")
        #expect(RulerMeasurement.centimetresText(72) == "2.5 cm") // an inch
        #expect(abs(RulerMeasurement.centimetres(fromPoints: 28.346_456_7) - 1) < 1e-6)
    }

    @Test func aStrokeRoundTheArcMeasuresTheAngleItSweeps() {
        let c = CGPoint(x: 100, y: 100)
        var measurement = RulerMeasurement(guide: .arc(center: c, radius: 50))
        for degrees in stride(from: 180.0, through: 315.0, by: 15) {
            let a = degrees * .pi / 180
            measurement.advance(to: CGPoint(x: c.x + 80 * cos(a), y: c.y + 80 * sin(a)))
        }
        #expect(abs(measurement.sweptDegrees - 135) < 1e-6)
        #expect(measurement.readout == "135°")
        #expect(measurement.length == 0)
    }

    @Test func theAngleShownWrapsAndSnapsToFifteenDegrees() {
        var ruler = Ruler(center: .zero, angle: 200 * .pi / 180)
        #expect(ruler.displayedDegrees == 20) // a straight edge turned half a turn is the same edge
        ruler.mode = .protractor
        #expect(ruler.displayedDegrees == 200)
        #expect(Ruler(center: .zero, angle: -30 * .pi / 180).displayedDegrees == 150)
        #expect(abs(Ruler.snappedAngle(44.2 * .pi / 180) - .pi / 4) < 1e-12)
        let free = 40 * CGFloat.pi / 180
        #expect(Ruler.snappedAngle(free) == free)
    }

    @Test func fingersMoveTheRulerOnlyOnItsBody() {
        #expect(level.contains(CGPoint(x: 500, y: 500)))
        #expect(level.contains(CGPoint(x: 1200, y: 540)))
        #expect(!level.contains(CGPoint(x: 500, y: 560)))
    }
}

@MainActor
@Suite("Ruler on the canvas")
struct CanvasRulerTests {
    @Test func aPenStrokeStartingByTheRulerIsDrawnStraightAlongItsEdge() throws {
        let controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: "CanvasRulerTests.\(UUID())")),
                                              penTray: PenTrayStore(fileURL: nil), pasteboard: .withUniqueName(),
                                              presentation: InkPresentation())
        let document = CanvasDocument(pageSize: .letter)
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
        controller.rulerVisible = true
        let ruler = try #require(controller.rulerView)
        ruler.layoutIfNeeded()
        #expect(ruler.superview === canvas)
        let center = ruler.ruler.center
        #expect(center == CGPoint(x: 516, y: 688))

        // A stroke starting just below the bottom edge.
        let viewStart = CGPoint(x: 300, y: center.y + Ruler.width / 2 + 10)
        let start = canvas.inputTransform.toCanvas(viewStart)
        canvas.live = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA(r: 0, g: 0, b: 0), brush: .pen, points: []))
        canvas.beginRulerSnap(at: start)
        let snap = try #require(canvas.rulerSnap)
        for (i, wobble) in [0, 8, -5, 12, -9].enumerated() {
            let raw = canvas.inputTransform.toCanvas(CGPoint(x: viewStart.x + CGFloat(i) * 60, y: viewStart.y + CGFloat(wobble)))
            let projected = snap.guide.project(raw)
            #expect(abs(canvas.inputTransform.toView(projected).y - (center.y + Ruler.width / 2)) < 1e-6)
        }
        canvas.endRulerSnap()
        #expect(canvas.rulerSnap == nil)
        canvas.live = nil

        controller.rulerVisible = false
        #expect(!canvas.subviews.contains { $0 is RulerView })
    }
}
