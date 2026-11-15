import CoreGraphics
import Foundation
@testable import InkKit
import Testing

/// Writing across a page boundary in continuous scrolling (NOT-89): the rules for which page takes which
/// part of a stroke, how the pieces look together, and undoing them as one.
@MainActor
@Suite("Writing across pages")
struct PageSeamTests {
    // Two 200 × 200 pages stacked with a 6-point gap, in one "sheet" space at scale 1.
    private let pageSize = CGSize(width: 200, height: 200)
    private let gap: CGFloat = 6
    private var pageTops: [CGFloat] {
        [0, pageSize.height + gap]
    }

    /// What `ContinuousCanvasView` does with each sample of one stroke: every page takes part while the
    /// sample is within reach of it, with a piece of its own in its own coordinates, and a page's piece
    /// is kept only if its ink reaches the page. Returns each page's kept pieces.
    private func relay(_ samples: [StrokePoint], brush: BrushDescriptor, reach: CGFloat? = nil) -> [[Stroke]] {
        let reach = reach ?? PageSeam.reach(for: brush)
        var pieces: [[Stroke]] = pageTops.map { _ in [] }
        var live: [LiveStroke?] = pageTops.map { _ in nil }
        func end(_ page: Int) {
            guard let piece = live[page] else { return }
            live[page] = nil
            let onPage = PageSeam.inkReachesPage(piece.stroke.points.map(\.location),
                                                 pageBounds: CGRect(origin: .zero, size: pageSize),
                                                 inkRadius: PageSeam.inkRadius(of: brush))
            if onPage {
                pieces[page].append(piece.stroke)
            }
        }
        for sample in samples {
            for (page, top) in pageTops.enumerated() {
                var p = sample
                p.location.y -= top
                if PageSeam.reaches(p.location, pageHeight: pageSize.height, reach: reach) {
                    if live[page] == nil {
                        live[page] = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA.swatches[0], brush: brush, points: []))
                    }
                    live[page]?.append(p, minSpacing: 0.15)
                } else {
                    end(page)
                }
            }
        }
        for page in pageTops.indices {
            end(page)
        }
        return pieces
    }

    /// The whole stroke as one, in sheet space: what the two pages should show between them.
    private func whole(_ samples: [StrokePoint], brush: BrushDescriptor) -> Stroke {
        let live = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA.swatches[0], brush: brush, points: []))
        for sample in samples {
            live.append(sample, minSpacing: 0.15)
        }
        return live.stroke
    }

    /// A wavy, varying-pressure stroke from `from` to `to` (sheet space), sampled about every point as
    /// the Pencil would be.
    private func samples(from: CGPoint, to: CGPoint, count: Int = 400) -> [StrokePoint] {
        (0 ..< count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            let x = from.x + (to.x - from.x) * t + sin(t * 9) * 18
            let y = from.y + (to.y - from.y) * t
            return StrokePoint(location: CGPoint(x: x, y: y), force: 0.35 + 0.4 * abs(sin(t * 5)), altitude: .pi / 2,
                               azimuth: 0, timestamp: Double(i) / 240)
        }
    }

    // MARK: Splitting a stroke

    @Test func aStrokeAcrossTheBoundaryBecomesOnePiecePerPageInEachPagesCoordinates() throws {
        let brush = BrushDescriptor.brushPen.sized(6, minimumRatio: 0.2)
        let pieces = relay(samples(from: CGPoint(x: 60, y: 120), to: CGPoint(x: 140, y: 320)), brush: brush)
        #expect(pieces.map(\.count) == [1, 1])
        let a = pieces[0][0].points.map(\.location), b = pieces[1][0].points.map(\.location)
        // The page above's piece runs on past its bottom edge, the page below's starts above its top: they
        // overlap across the gap, so each is whole up to its edge.
        #expect(a.first?.y == 120)
        #expect(try #require(a.last?.y) > pageSize.height + gap)
        #expect(try #require(b.first?.y) < -gap)
        #expect(try abs(#require(b.last?.y) - (320 - pageTops[1])) < 1)
        // Neither piece's ends (and their tapers) are on its page.
        let reach = PageSeam.reach(for: brush)
        #expect(reach >= brush.taper.endLength + PageSeam.inkRadius(of: brush))
        #expect(try #require(a.last?.y) - pageSize.height >= reach - 2)
        #expect(try -#require(b.first?.y) >= reach - 2)
    }

    @Test func thePiecesLookLikeTheStrokeTheyCameFrom() throws {
        // Tapered, smoothed and speed-sensitive: the brush most likely to show a join.
        let brush = BrushDescriptor.brushPen.sized(8, minimumRatio: 0.15)
        let input = samples(from: CGPoint(x: 50, y: 110), to: CGPoint(x: 150, y: 330))
        let pieces = relay(input, brush: brush)
        let reference = whole(input, brush: brush)
        let scale: CGFloat = 2
        for (page, top) in pageTops.enumerated() {
            let shown = try #require(PageRenderer.image(strokes: pieces[page], objects: [],
                                                        region: CGRect(origin: .zero, size: pageSize), scale: scale))
            let expected = try #require(PageRenderer.image(strokes: [reference], objects: [],
                                                           region: CGRect(origin: CGPoint(x: 0, y: top), size: pageSize),
                                                           scale: scale))
            let difference = maxAlphaDifference(shown, expected)
            // Antialiasing aside, the same ink: no thinning, gap or blob at the page's edge.
            #expect(difference <= 12, "page \(page) differs by up to \(difference)/255")
        }

        // Cut at the edge instead, the pieces' tapers and end caps show at the join.
        let cut = relay(input, brush: brush, reach: 0)
        let below = try #require(PageRenderer.image(strokes: cut[1], objects: [], region: CGRect(origin: .zero, size: pageSize),
                                                    scale: scale))
        let expectedBelow = try #require(PageRenderer.image(strokes: [reference], objects: [],
                                                            region: CGRect(origin: CGPoint(x: 0, y: pageTops[1]), size: pageSize),
                                                            scale: scale))
        #expect(maxAlphaDifference(below, expectedBelow) > 40)
    }

    @Test func inkThatOnlyReachesTheGapStaysOnItsPage() {
        let brush = TestBrush.pen.brush(width: 3)
        let pieces = relay(samples(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 100, y: 203), count: 60), brush: brush)
        #expect(pieces.map(\.count) == [1, 0])
    }

    @Test func goingBackUpStartsANewPieceOnThePageAbove() {
        let brush = TestBrush.pen.brush(width: 3)
        let down = samples(from: CGPoint(x: 60, y: 120), to: CGPoint(x: 100, y: 330), count: 300)
        let up = samples(from: CGPoint(x: 100, y: 330), to: CGPoint(x: 140, y: 100), count: 300)
        let pieces = relay(down + up, brush: brush)
        #expect(pieces.map(\.count) == [2, 1])
    }

    @Test func theReachCoversTheTaperAndNibButIsBounded() {
        var brush = TestBrush.pen.brush(width: 4) // no tilt shading
        brush.taper = .none
        #expect(PageSeam.reach(for: brush) == 4 + PageSeam.extraReach) // no taper: the nib and a margin
        brush.taper = .init(startLength: 30, endLength: 50)
        #expect(PageSeam.reach(for: brush) == 50 + 4 + PageSeam.extraReach)
        brush.taper = .init(startLength: 500, endLength: 500)
        #expect(PageSeam.reach(for: brush) == PageSeam.maxReach)
        #expect(PageSeam.reach(eraserRadius: 10) == 10 + PageSeam.extraReach)
        brush.tilt.enabled = true // shading widens the nib
        #expect(PageSeam.inkRadius(of: brush) > 2)
        #expect(PageSeam.reaches(CGPoint(x: -500, y: -10), pageHeight: 100, reach: 10)) // sideways doesn't matter
        #expect(!PageSeam.reaches(CGPoint(x: 50, y: 111), pageHeight: 100, reach: 10))
    }

    // MARK: Undo

    @Test func undoingOnePagesPieceUndoesTheOtherPagesToo() {
        let notebook = InkNotebook(pageCount: 3)
        let (a, b, c) = (notebook.pages[0], notebook.pages[1], notebook.pages[2])
        c.add(makeStroke(at: CGPoint(x: 10, y: 10))) // not part of it
        let group = UUID()
        for page in [a, b] {
            page.editGroup = group
            page.add(makeStroke(at: CGPoint(x: 50, y: 50)))
            page.editGroup = nil
        }
        #expect(a.undoGroup == group && b.undoGroup == group && c.undoGroup == nil)

        // What the canvas's undo does: its own page, then the rest of the group.
        b.undo()
        notebook.undoGroup(group)
        #expect(a.strokes.isEmpty && b.strokes.isEmpty)
        #expect(c.strokes.count == 1)
        #expect(a.redoGroup == group && b.redoGroup == group)

        a.redo()
        notebook.redoGroup(group)
        #expect(a.strokes.count == 1 && b.strokes.count == 1)
        #expect(a.undoGroup == group && b.undoGroup == group)
        #expect(c.strokes.count == 1)
    }

    @Test func aPageEditedSinceKeepsItsPiece() {
        let notebook = InkNotebook(pageCount: 2)
        let (a, b) = (notebook.pages[0], notebook.pages[1])
        let group = UUID()
        for page in [a, b] {
            page.editGroup = group
            page.add(makeStroke(at: CGPoint(x: 50, y: 50)))
            page.editGroup = nil
        }
        b.add(makeStroke(at: CGPoint(x: 90, y: 90))) // written on its own afterwards
        a.undo()
        notebook.undoGroup(group)
        #expect(a.strokes.isEmpty)
        #expect(b.strokes.count == 2)
    }

    @Test func aStrokeThatCrossedBackIsUndoneWhole() {
        let notebook = InkNotebook(pageCount: 2)
        let (a, b) = (notebook.pages[0], notebook.pages[1])
        let group = UUID()
        for page in [a, b, a] { // down onto the page below and back up
            page.editGroup = group
            page.add(makeStroke(at: CGPoint(x: 50, y: 50)))
            page.editGroup = nil
        }
        a.undo()
        notebook.undoGroup(group)
        #expect(a.strokes.isEmpty && b.strokes.isEmpty)
        #expect(!a.canUndo && !b.canUndo)
    }

    @Test func groupsStayInStepWithTheHistory() {
        let page = CanvasDocument()
        let group = UUID()
        page.add(makeStroke(at: CGPoint(x: 10, y: 10)))
        page.editGroup = group
        page.add(makeStroke(at: CGPoint(x: 20, y: 20)))
        page.editGroup = nil
        page.add(makeStroke(at: CGPoint(x: 30, y: 30)))
        #expect(page.undoGroup == nil)
        page.undo()
        #expect(page.undoGroup == group && page.redoGroup == nil)
        page.undo()
        #expect(page.undoGroup == nil && page.redoGroup == group)
        page.redo()
        #expect(page.undoGroup == group)
        page.add(makeStroke(at: CGPoint(x: 40, y: 40))) // a new edit clears the redo history
        #expect(page.redoGroup == nil && page.undoGroup == nil)
        page.rotate()
        #expect(page.undoGroup == nil && !page.canUndo)
    }
}

/// The largest difference in alpha (0–255) between two images of the same size.
private func maxAlphaDifference(_ a: CGImage, _ b: CGImage) -> Int {
    guard a.width == b.width, a.height == b.height else { return 255 }
    func alphas(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: data.count, by: 4).map { data[$0] }
    }
    return zip(alphas(a), alphas(b)).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
}
