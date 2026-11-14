import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Scribble")
struct ScribbleTests {
    /// A horizontal zigzag `passes` passes long across `width`, starting at `origin`, sampled every 2 pt.
    func zigzag(passes: Int, width: CGFloat = 120, drop: CGFloat = 4, origin: CGPoint = CGPoint(x: 100, y: 100))
        -> [CGPoint] {
        var points: [CGPoint] = []
        for pass in 0 ..< passes {
            let forward = pass % 2 == 0
            for step in stride(from: CGFloat(0), through: width, by: 2) {
                let x = forward ? step : width - step
                points.append(CGPoint(x: origin.x + x, y: origin.y + CGFloat(pass) * drop + step / width * drop))
            }
        }
        return points
    }

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

    // MARK: Scratch-out

    @Test("Scribbling back and forth is a scratch-out")
    func zigzagIsScratch() {
        #expect(Scribble.isScratchOut(zigzag(passes: 6), minSize: 24))
        // A diagonal scratch too: the axis follows the scribble.
        let diagonal = zigzag(passes: 6).map { CGPoint(x: $0.x * 0.7 - $0.y * 0.7, y: $0.x * 0.7 + $0.y * 0.7) }
        #expect(Scribble.isScratchOut(diagonal, minSize: 24))
    }

    @Test("Too few passes, a small scribble and writing aren't scratch-outs")
    func notScratch() {
        #expect(!Scribble.isScratchOut(zigzag(passes: 3), minSize: 24)) // two turns
        #expect(!Scribble.isScratchOut(zigzag(passes: 6, width: 10), minSize: 24))
        #expect(!Scribble.isScratchOut(cursive(from: CGPoint(x: 100, y: 100), letters: 8), minSize: 24))
        #expect(!Scribble.isScratchOut([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], minSize: 24))
    }

    @Test("Small wobbles don't count as turns")
    func hysteresis() {
        let values: [CGFloat] = [0, 50, 48, 100, 98, 0, 2, 100]
        #expect(Scribble.reversals(along: values, hysteresis: 20) == 2)
        #expect(Scribble.reversals(along: values, hysteresis: 1) == 4) // 50→48, 48→100, 100→98, 0→2
    }

    @Test("A scratch erases the strokes mostly under it")
    func scratchTargets() {
        let scratch = zigzag(passes: 6) // x 100...220, y 100...124
        let underneath = candidate(cursive(from: CGPoint(x: 120, y: 112), letters: 4))
        let elsewhere = candidate(cursive(from: CGPoint(x: 400, y: 400), letters: 4))
        let straddling = candidate((0 ..< 40).map { CGPoint(x: 200 + CGFloat($0) * 5, y: 110) }) // mostly outside
        let hit = Scribble.scratchOutTargets(scratch, candidates: [underneath, elsewhere, straddling], pad: 4)
        #expect(hit == [underneath.id])
    }

    // MARK: Circle to select

    @Test("A closed loop is a circle; an open arc or a small loop isn't")
    func loops() {
        let c = CGPoint(x: 300, y: 300)
        #expect(Scribble.isClosedLoop(circle(center: c, radius: 80), minSize: 24))
        #expect(Scribble.isClosedLoop(circle(center: c, radius: 80, turns: 1.05), minSize: 24))
        #expect(!Scribble.isClosedLoop(circle(center: c, radius: 80, turns: 0.6), minSize: 24))
        #expect(!Scribble.isClosedLoop(circle(center: c, radius: 8), minSize: 24))
        #expect(!Scribble.isClosedLoop(zigzag(passes: 6), minSize: 24))
    }

    @Test("A loop selects the strokes mostly inside it")
    func loopSelection() {
        let loop = circle(center: CGPoint(x: 300, y: 300), radius: 100)
        let inside = candidate(cursive(from: CGPoint(x: 250, y: 300), letters: 4))
        let outside = candidate(cursive(from: CGPoint(x: 600, y: 300), letters: 4))
        let crossing = candidate((0 ..< 50).map { CGPoint(x: 350 + CGFloat($0) * 6, y: 300) })
        #expect(Scribble.loopSelection(loop, candidates: [inside, outside, crossing]) == [inside.id])
    }

    @Test("The principal axis follows the spread of the points")
    func principalAxis() {
        let horizontal = Scribble.principalAxis([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 1), CGPoint(x: 20, y: 0)])
        #expect(abs(horizontal.x) > 0.99)
        let vertical = Scribble.principalAxis([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 10), CGPoint(x: 0, y: 20)])
        #expect(abs(vertical.y) > 0.99)
    }
}
