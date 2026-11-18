import CoreGraphics
import Foundation
@testable import InkKit
import Testing

/// Deterministic random numbers, so a failing sequence of edits can be replayed.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randomRect(_ rng: inout SeededRandom, in area: CGRect, maxSide: CGFloat) -> CGRect {
    CGRect(x: .random(in: area.minX ... area.maxX, using: &rng), y: .random(in: area.minY ... area.maxY, using: &rng),
           width: .random(in: 0 ... maxSide, using: &rng), height: .random(in: 0 ... maxSide, using: &rng))
}

/// A wandering stroke of `count` points starting near `origin`, with random pressure, tilt and timing.
private func scribble(_ rng: inout SeededRandom, brush: BrushDescriptor, origin: CGPoint, count: Int = 12,
                      step: CGFloat = 12) -> Stroke {
    var p = origin, t = 0.0
    var points: [StrokePoint] = []
    for _ in 0 ..< count {
        points.append(StrokePoint(location: p, force: .random(in: 0 ... 1, using: &rng),
                                  altitude: .random(in: 0.1 ... (.pi / 2), using: &rng),
                                  azimuth: .random(in: -.pi ... .pi, using: &rng), timestamp: t))
        p.x += .random(in: -step ... step, using: &rng)
        p.y += .random(in: -step ... step, using: &rng)
        t += .random(in: 0.002 ... 0.05, using: &rng)
    }
    return Stroke(id: UUID(), color: RGBA.swatches[0], brush: brush, points: points)
}

@Suite("Spatial grid")
struct SpatialGridTests {
    /// The positions whose rects intersect `rect`, by walking them all.
    private func bruteForce(_ rects: [CGRect], _ rect: CGRect) -> [Int] {
        rects.indices.filter { rects[$0].intersects(rect) }
    }

    @Test func queriesMatchAScanInZOrder() {
        var rng = SeededRandom(state: 1)
        let area = CGRect(x: -200, y: -200, width: 1400, height: 1600)
        var rects = (0 ..< 800).map { _ in randomRect(&rng, in: area, maxSide: 90) }
        rects += [.null, CGRect(x: -5000, y: -5000, width: 10000, height: 10000), .infinite,
                  CGRect(x: 10, y: 10, width: 0, height: 0)]
        let grid = SpatialGrid(bounds: rects)
        #expect(grid.count == rects.count)
        for _ in 0 ..< 400 {
            let query = randomRect(&rng, in: area, maxSide: 300)
            #expect(grid.query(query) == bruteForce(rects, query))
        }
        // Rects bigger than the grid is worth walking, and degenerate ones.
        for query in [CGRect.infinite, area, .null, CGRect(x: 30, y: 30, width: 0, height: 0)] {
            #expect(grid.query(query) == bruteForce(rects, query))
        }
    }

    @Test func overlappingItemsComeBackBottomFirst() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        var grid = SpatialGrid(bounds: [rect, rect.offsetBy(dx: 50, dy: 0), rect])
        #expect(grid.query(CGRect(x: 60, y: 10, width: 1, height: 1)) == [0, 1, 2])
        grid.insert(rect, at: 1)
        #expect(grid.query(CGRect(x: 60, y: 10, width: 1, height: 1)) == [0, 1, 2, 3])
        #expect(grid.query(CGRect(x: 120, y: 10, width: 1, height: 1)) == [2])
        grid.remove(at: 0)
        #expect(grid.query(CGRect(x: 120, y: 10, width: 1, height: 1)) == [1])
    }

    @Test func randomEditsKeepItInStepWithTheArray() {
        var rng = SeededRandom(state: 2)
        let area = CGRect(x: 0, y: 0, width: 800, height: 1000)
        var rects = (0 ..< 200).map { _ in randomRect(&rng, in: area, maxSide: 60) }
        var grid = SpatialGrid(bounds: rects)
        for step in 0 ..< 3000 {
            switch Int.random(in: 0 ..< 5, using: &rng) {
            case 0: // insert a run anywhere
                let at = Int.random(in: 0 ... rects.count, using: &rng)
                let new = (0 ..< Int.random(in: 1 ... 4, using: &rng)).map { _ in
                    randomRect(&rng, in: area, maxSide: 60)
                }
                rects.insert(contentsOf: new, at: at)
                grid.replaceSubrange(at ..< at, with: new)
            case 1 where !rects.isEmpty: // remove a run
                let at = Int.random(in: 0 ..< rects.count, using: &rng)
                let end = min(rects.count, at + Int.random(in: 1 ... 3, using: &rng))
                rects.removeSubrange(at ..< end)
                grid.replaceSubrange(at ..< end, with: [])
            case 2 where !rects.isEmpty: // move one
                let at = Int.random(in: 0 ..< rects.count, using: &rng)
                rects[at] = randomRect(&rng, in: area, maxSide: 60)
                grid.update(at: at, bounds: rects[at])
            case 3 where !rects.isEmpty: // replace a run with a different number (an erase's pieces)
                let at = Int.random(in: 0 ..< rects.count, using: &rng)
                let end = min(rects.count, at + Int.random(in: 0 ... 2, using: &rng))
                let new = (0 ..< Int.random(in: 0 ... 3, using: &rng)).map { _ in
                    randomRect(&rng, in: area, maxSide: 60)
                }
                rects.replaceSubrange(at ..< end, with: new)
                grid.replaceSubrange(at ..< end, with: new)
            default: // insert at the same place over and over: order keys run out of room and renumber
                let at = min(rects.count, 3)
                let new = randomRect(&rng, in: area, maxSide: 60)
                rects.insert(new, at: at)
                grid.insert(new, at: at)
            }
            #expect(grid.count == rects.count)
            if step % 10 == 0 {
                let query = randomRect(&rng, in: area, maxSide: 200)
                #expect(grid.query(query) == bruteForce(rects, query), "step \(step)")
            }
        }
        for at in rects.indices {
            #expect(grid.bounds(at: at) == rects[at])
        }
    }
}

@Suite("Stroke reach")
struct StrokeReachTests {
    /// Reach is what the index files a stroke under; queries only find a stroke whose ink reaches a rect if
    /// its reach holds all of that ink, for every brush, pressure, tilt and speed.
    @Test(arguments: BrushDescriptor.bundled)
    func reachHoldsTheInk(brush: BrushDescriptor) {
        var rng = SeededRandom(state: UInt64(truncatingIfNeeded: brush.name.hashValue))
        for tilt in [false, true] {
            for width in [brush.size.lowerBound, brush.maxWidth, brush.maxWidth * 3] {
                var b = brush.sized(width, minimumRatio: 0.25)
                b.tilt.enabled = tilt && brush.tilt.enabled
                for _ in 0 ..< 20 {
                    let stroke = scribble(&rng, brush: b, origin: CGPoint(x: 300, y: 300),
                                          count: .random(in: 1 ... 30, using: &rng),
                                          step: .random(in: 1 ... 40, using: &rng))
                    let ink = StrokeRenderer.geometry(for: stroke).bounds
                    let reach = StrokeIndex.reach(of: stroke)
                    #expect(ink.isNull || reach.contains(ink), "\(brush.name) ink \(ink) reach \(reach)")
                }
            }
        }
    }

    @Test func aStrokeWithNoPointsReachesNothing() {
        let stroke = Stroke(id: UUID(), color: RGBA.swatches[0], brush: .pen, points: [])
        #expect(StrokeIndex.reach(of: stroke).isNull)
    }
}

@MainActor
@Suite("Stroke index on a page")
struct PageStrokeIndexTests {
    private static let area = CGRect(x: 0, y: 0, width: 800, height: 1000)

    /// The index agrees with the page: same count, every stroke and object filed under its own rect, and
    /// queries give what walking the page gives.
    private func expectInStep(_ page: CanvasDocument, _ rng: inout SeededRandom, _ note: String) {
        let index = page.strokeIndex
        #expect(index.strokeCount == page.strokes.count, "\(note)")
        #expect(index.objectCount == page.objects.count, "\(note)")
        guard index.strokeCount == page.strokes.count, index.objectCount == page.objects.count else { return }
        for (i, stroke) in page.strokes.enumerated() where index.strokeBounds(at: i) != StrokeIndex.reach(of: stroke) {
            Issue.record("\(note): stroke \(i) filed under a stale rect")
        }
        for _ in 0 ..< 3 {
            let rect = randomRect(&rng, in: Self.area, maxSide: 250)
            let strokes = page.strokes.indices.filter { StrokeIndex.reach(of: page.strokes[$0]).intersects(rect) }
            #expect(page.strokeIndices(in: rect) == strokes, "\(note)")
            let objects = page.objects.filter { $0.bounds.intersects(rect) }.map(\.id)
            #expect(page.objects(in: rect).map(\.id) == objects, "\(note)")
        }
    }

    private func randomStroke(_ rng: inout SeededRandom) -> Stroke {
        let brushes: [BrushDescriptor] = [.pen, .pencil, .highlighter, .pixelEraser]
        let origin = CGPoint(x: .random(in: 0 ... 800, using: &rng), y: .random(in: 0 ... 1000, using: &rng))
        return scribble(&rng, brush: brushes.randomElement(using: &rng)!, origin: origin,
                        count: .random(in: 1 ... 10, using: &rng))
    }

    private func randomSelection(_ page: CanvasDocument, _ rng: inout SeededRandom) -> PageSelection {
        PageSelection(strokeIDs: Set(page.strokes.filter { _ in Bool.random(using: &rng) }.prefix(6).map(\.id)),
                      objectIDs: Set(page.objects.filter { _ in Bool.random(using: &rng) }.map(\.id)))
    }

    /// Every kind of edit, live erase, preview, undo and redo, in random order, checked against walking
    /// the page after each.
    @Test(arguments: [3, 4, 5] as [UInt64])
    func randomEditsUndoAndRedoKeepItInStep(seed: UInt64) {
        var rng = SeededRandom(state: seed)
        let page = CanvasDocument(pageSize: .letter)
        for _ in 0 ..< 30 {
            page.add(randomStroke(&rng))
        }
        for step in 0 ..< 400 {
            if Bool.random(using: &rng) {
                editInk(page, &rng, note: "seed \(seed) step \(step)")
            } else {
                editPage(page, &rng)
            }
            expectInStep(page, &rng, "seed \(seed) step \(step)")
        }
        while page.undo() {}
        expectInStep(page, &rng, "seed \(seed) all undone")
        while page.redo() {}
        expectInStep(page, &rng, "seed \(seed) all redone")
        page.rotate()
        expectInStep(page, &rng, "seed \(seed) rotated")
        let copy = page.copy()
        copy.add(randomStroke(&rng))
        expectInStep(copy, &rng, "seed \(seed) copy")
        expectInStep(page, &rng, "seed \(seed) original of copy")
    }

    /// One random change to the ink: drawing, the three erasers (live, then recorded) or a lasso drag.
    private func editInk(_ page: CanvasDocument, _ rng: inout SeededRandom, note: String) {
        switch Int.random(in: 0 ..< 7, using: &rng) {
        case 0, 1:
            page.add(randomStroke(&rng))
        case 2: // a pixel eraser cutting a stroke in two
            if let i = page.strokes.indices.randomElement(using: &rng), !page.strokes[i].brush.erases,
               page.strokes[i].points.count >= 4 {
                let original = page.strokes[i], half = original.points.count / 2
                var a = original, b = original
                a = Stroke(id: UUID(), color: a.color, brush: a.brush, points: Array(original.points[..<half]))
                b = Stroke(id: UUID(), color: b.color, brush: b.brush, points: Array(original.points[half...]))
                page.add(randomStroke(&rng), splits: [.init(index: i, original: original, pieces: [a, b])])
            }
        case 3: // a stroke erase, found by position
            let positions = page.strokeIndices(in: randomRect(&rng, in: Self.area, maxSide: 150))
            page.recordErase(page.remove(at: positions.prefix(3)))
        case 4: // a stroke erase, found by id
            page.recordErase(page.remove(ids: Set(page.strokes.prefix(2).map(\.id))))
        case 5: // a standard erase: cut and replace during the gesture, recorded at the end
            let before = page.strokes
            for _ in 0 ..< 3 {
                guard let i = page.strokes.indices.randomElement(using: &rng) else { break }
                let pieces = (0 ..< Int.random(in: 0 ... 2, using: &rng)).map { _ in randomStroke(&rng) }
                if Bool.random(using: &rng) {
                    page.replace(at: i, with: pieces)
                } else {
                    page.replace(id: page.strokes[i].id, with: pieces)
                }
            }
            page.recordReplace(before: before)
        default: // a lasso drag: previews, then commit or cancel
            let session = page.beginTransform(randomSelection(page, &rng))
            for k in 1 ... 3 {
                page.previewTransform(session, by: CGAffineTransform(translationX: CGFloat(k) * 7, y: -5))
                expectInStep(page, &rng, "\(note) preview")
            }
            if Bool.random(using: &rng) {
                page.commitTransform(session, by: CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 1.2, y: 1.2))
            } else {
                page.cancelTransform(session)
            }
        }
    }

    /// One random change to the page: paste, restyle, arrange, objects, delete, clear, refine, undo or redo.
    private func editPage(_ page: CanvasDocument, _ rng: inout SeededRandom) {
        switch Int.random(in: 7 ..< 16, using: &rng) {
        case 7:
            page.insert(strokes: [randomStroke(&rng)], objects: [PlaceholderObject(
                frame: randomRect(&rng, in: Self.area, maxSide: 100), color: PenColor(rgb: 0x202020)
            )])
        case 8:
            page.restyle(randomSelection(page, &rng), strokes: { stroke in
                var s = stroke
                s.brush = s.brush.sized(s.brush.maxWidth * 2, minimumRatio: 0.25)
                return s
            }, objects: { $0.applying(CGAffineTransform(translationX: 3, y: 0)) })
        case 9:
            page.arrange(randomSelection(page, &rng), Bool.random(using: &rng) ? .bringToFront : .sendToBack)
        case 10:
            let frame = randomRect(&rng, in: Self.area, maxSide: 120)
            page.addObject(PlaceholderObject(frame: frame, color: PenColor(rgb: 0x202020)))
        case 11:
            if let object = page.objects.randomElement(using: &rng) {
                page.replaceObjects(before: [object], after: [object.applying(.init(translationX: 0, y: 40))])
            }
        case 12:
            page.delete(randomSelection(page, &rng))
        case 13:
            if Int.random(in: 0 ..< 6, using: &rng) == 0 {
                page.clear()
            } else if let stroke = page.strokes.last {
                _ = page.updatePoint(strokeID: stroke.id, index: 0) { $0.location.x += 30 }
            }
        default:
            for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
                if Bool.random(using: &rng) {
                    page.undo()
                } else {
                    page.redo()
                }
            }
        }
    }

    @Test func aPageOpensWithTheIndexItsFileWasPreparedWith() throws {
        var rng = SeededRandom(state: 6)
        let strokes = (0 ..< 50).map { _ in randomStroke(&rng) }
        var file = InkPageFile(pageID: UUID(), strokes: strokes)
        #expect(file.preparedIndex == nil)
        file.prepareIndex()
        #expect(file.preparedIndex?.strokeCount == 50)
        let page = CanvasDocument(file: file, pageSize: .letter)
        expectInStep(page, &rng, "opened")
        // Changing the strokes drops what was prepared for them, and the page builds its own.
        file.strokes.removeLast()
        #expect(file.preparedIndex == nil)
        expectInStep(CanvasDocument(file: file, pageSize: .letter), &rng, "unprepared")
        // A decoded file compares equal whether or not its index is prepared.
        let decoded = try InkPageFile(data: file.encoded())
        var prepared = decoded
        prepared.prepareIndex()
        #expect(prepared == decoded)
    }

    @Test func queriesFindOnlyWhatsNearAndInPageOrder() {
        let page = CanvasDocument(pageSize: .letter)
        func dot(_ x: CGFloat, _ y: CGFloat) -> Stroke {
            Stroke(id: UUID(), color: RGBA.swatches[0], brush: .pen,
                   points: [StrokePoint(location: CGPoint(x: x, y: y), force: 1, altitude: .pi / 2, azimuth: 0,
                                        timestamp: 0)])
        }
        let a = dot(100, 100), b = dot(500, 500), c = dot(102, 101)
        page.add(a)
        page.add(b)
        page.add(c)
        let near = CGRect(x: 95, y: 95, width: 10, height: 10)
        #expect(page.strokes(in: near).map(\.id) == [a.id, c.id])
        page.arrange(PageSelection(strokeIDs: [c.id]), .sendToBack)
        #expect(page.strokes(in: near).map(\.id) == [c.id, a.id])
        page.undo()
        #expect(page.strokes(in: near).map(\.id) == [a.id, c.id])
        #expect(page.strokes(in: CGRect(x: 300, y: 300, width: 10, height: 10)).isEmpty)
    }
}
