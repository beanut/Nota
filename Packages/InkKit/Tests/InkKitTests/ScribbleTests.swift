import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Scribble")
struct ScribbleTests {
    /// A circle of `radius` round `center`, `turns` times round (1 closes it), sampled every 5°.
    func circle(center: CGPoint, radius: CGFloat, turns: CGFloat = 1) -> [CGPoint] {
        stride(from: CGFloat(0), through: 360 * turns, by: 5).map { deg in
            let a = deg * .pi / 180
            return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        }
    }

    /// A line of handwriting-like loops moving steadily right ("eeee").
    func cursive(from origin: CGPoint, letters: Int) -> [CGPoint] {
        var points: [CGPoint] = []
        for letter in 0 ..< letters {
            for deg in stride(from: CGFloat(0), to: 360, by: 15) {
                let a = deg * .pi / 180
                points.append(CGPoint(x: origin.x + CGFloat(letter) * 18 + CGFloat(deg) / 360 * 18 + cos(a) * 6,
                                      y: origin.y + sin(a) * 8))
            }
        }
        return points
    }

    func candidate(_ points: [CGPoint]) -> Scribble.Candidate {
        Scribble.Candidate(id: UUID(), points: points, bounds: LassoGeometry.bounds(of: points))
    }

    // MARK: Circle to select

    @Test("A closed loop is a circle; an open arc or a small loop isn't")
    func loops() {
        let c = CGPoint(x: 300, y: 300)
        #expect(Scribble.isClosedLoop(circle(center: c, radius: 80), minSize: 24))
        #expect(Scribble.isClosedLoop(circle(center: c, radius: 80, turns: 1.05), minSize: 24))
        #expect(!Scribble.isClosedLoop(circle(center: c, radius: 80, turns: 0.6), minSize: 24))
        #expect(!Scribble.isClosedLoop(circle(center: c, radius: 8), minSize: 24))
        // A scribble that fills its bounds runs far longer than one loop.
        #expect(!Scribble.isClosedLoop(circle(center: c, radius: 80, turns: 3), minSize: 24))
    }

    @Test("A loop selects the strokes mostly inside it")
    func loopSelection() {
        let loop = circle(center: CGPoint(x: 300, y: 300), radius: 100)
        let inside = candidate(cursive(from: CGPoint(x: 250, y: 300), letters: 4))
        let outside = candidate(cursive(from: CGPoint(x: 600, y: 300), letters: 4))
        let crossing = candidate((0 ..< 50).map { CGPoint(x: 350 + CGFloat($0) * 6, y: 300) })
        #expect(Scribble.loopSelection(loop, candidates: [inside, outside, crossing]) == [inside.id])
    }
}
