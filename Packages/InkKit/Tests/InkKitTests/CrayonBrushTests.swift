import CoreGraphics
import Foundation
@testable import InkKit
import Metal
import Testing

/// Whether this machine can run the crayon's shaders (every iPad and Apple-silicon simulator can).
private let hasMetal = WaxRenderer.shared != nil

/// The crayon (NOT-93): a raster brush drawn with Metal (`WaxRenderer`).
@MainActor
@Suite("Crayon brush")
struct CrayonBrushTests {
    // MARK: The brush

    /// The rendering tests skip without Metal, so a shader that stops compiling would only show as skips:
    /// wherever there is a GPU, the renderer must build.
    @Test func theShadersCompileWhereverThereIsAGPU() {
        if MTLCreateSystemDefaultDevice() != nil {
            #expect(WaxRenderer.shared != nil, "WaxShaders.source didn't compile")
        }
    }

    @Test func itIsInThePencilFamilyWithAFixedID() {
        #expect(BrushDescriptor.pencils.contains(.crayon))
        #expect(BrushDescriptor.bundled(id: BrushDescriptor.crayon.id) == .crayon)
        #expect(BrushDescriptor.crayon.id.uuidString == "6E6F7461-0000-4000-8000-00000000000D")
        #expect(BrushDescriptor.crayon.clamped() == .crayon)
    }

    @Test func itIsARasterBrushOnTheStampPath() {
        let crayon = BrushDescriptor.crayon
        #expect(crayon.isRaster)
        #expect(crayon.renderPath == .stamp)
        #expect(crayon.pressure.isActive && crayon.pressureOpacity.isActive && crayon.tilt.enabled)
        #expect(!BrushDescriptor.pencil.isRaster && !BrushDescriptor.softPencil.isRaster)
        #expect(BrushDescriptor.bundled.filter(\.isRaster) == [.crayon])
    }

    @Test func settingsAdjustItWithoutLosingItsCharacter() {
        let personal = BrushDescriptor.crayon.personalized(width: 6, minimumWidthRatio: 0.25,
                                                           pressureExponent: 0.6, tilt: true)
        #expect(personal.texture == BrushDescriptor.crayon.texture)
        #expect(personal.isRaster)
        #expect(personal.maxWidth == 6)
    }

    @Test func theEraserTreatsItAsPencilInk() {
        #expect(EraserTarget.pencil.erases(.crayon))
        #expect(EraserTarget.all.erases(.crayon))
        #expect(!EraserTarget.highlighter.erases(.crayon))
    }

    // MARK: Saving

    @Test func theWaxTextureRoundTripsAndClamps() throws {
        let data = try BrushDescriptor.crayon.jsonData()
        #expect(try BrushDescriptor(json: data) == .crayon)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let texture = try #require(object["texture"] as? [String: Any])
        #expect(texture["wax"] != nil)

        let wild = Data(#"{"name": "Wild", "texture": {"wax": {"scale": 40, "contrast": -3}}}"#.utf8)
        #expect(try BrushDescriptor(json: wild).texture == .wax(scale: 8, contrast: 0, seed: 0))
    }

    /// A build that doesn't know the wax texture reads it the way this one reads any unknown texture: as
    /// none, keeping the rest of the brush, so the crayon draws as solid stamps of the same shape.
    @Test func aBuildWithoutWaxDrawsItAsPlainStamps() throws {
        let data = try BrushDescriptor.crayon.jsonData()
        let json = try #require(String(data: data, encoding: .utf8))
        let future = json.replacingOccurrences(of: "\"wax\"", with: "\"someLaterTexture\"")
        let degraded = try BrushDescriptor(json: Data(future.utf8))
        #expect(degraded.texture == .none)
        #expect(!degraded.isRaster)
        #expect(degraded.renderPath == .stamp)
        var expected = BrushDescriptor.crayon
        expected.texture = .none
        #expect(degraded == expected)
    }

    @Test func crayonStrokesSurviveTheInkFile() throws {
        let stroke = builtInStroke(.crayon, wave: 0)
        let file = InkPageFile(pageID: UUID(), strokes: [stroke])
        let decoded = try InkPageFile(data: file.encoded())
        #expect(decoded.strokes.first?.brush == stroke.brush)
        #expect(decoded.strokes.first?.brush.isRaster == true)
    }

    // MARK: Geometry

    /// Each stamp carries where the crayon's own texture sits under it: the stroke's offset, shifted with the
    /// direction of travel.
    @Test func itsStampsCarryTheStrokesGrainTurnedByTheHeading() throws {
        let there = straight(force: 0.6, from: 20, to: 280)
        let back = straight(force: 0.6, from: 280, to: 20)
        func grains(_ stroke: Stroke) -> [CGPoint] {
            StrokeRenderer.geometry(for: stroke).runs.flatMap(\.stamps).map(\.grain)
        }
        let shift = RasterStamp.headingShift
        let own = there.waxGrain
        let middle = try #require(grains(there).dropFirst(20).first)
        #expect(abs(middle.x - (own.x + shift)) < 0.01 && abs(middle.y - own.y) < 0.01)
        let returning = try #require(grains(back).dropFirst(20).first)
        #expect(abs(returning.x - (own.x - shift)) < 0.01)
        // Strokes made at different times have their own grain; the pieces of an erased one keep theirs.
        var later = there
        later.createdAt = there.createdAt.addingTimeInterval(0.5)
        #expect(later.waxGrain != there.waxGrain)
        #expect(there.waxGrain == there.waxGrain)
    }

    @Test func itsRunsCarryTheNibStampsTheGPUDraws() {
        let crayon = StrokeRenderer.geometry(for: builtInStroke(.crayon, wave: 0))
        let stamps = crayon.runs.flatMap(\.stamps)
        #expect(stamps.count > 100)
        #expect(stamps.allSatisfy { crayon.bounds.insetBy(dx: -1, dy: -1).contains($0.tip.center) })
        let pen = StrokeRenderer.geometry(for: builtInStroke(.pen, wave: 0))
        #expect(pen.runs.flatMap(\.stamps).isEmpty)
        // A tap is one stamp.
        var tap = builtInStroke(.crayon, wave: 0)
        tap.points = [tap.points[0]]
        #expect(StrokeRenderer.geometry(for: tap).runs.flatMap(\.stamps).count == 1)
    }

    // MARK: Rendering

    @Test(.enabled(if: hasMetal, "needs a Metal device"))
    func theSameInkDrawsTheSamePixelsEveryTime() throws {
        let page = page(of: [builtInStroke(.crayon, wave: 0), builtInStroke(.crayon, wave: 2)])
        let first = try #require(render(page)), second = try #require(render(page))
        let diff = try #require(compare(first, second))
        #expect(diff.differingPixels == 0)
    }

    /// The grain is fixed to the page: drawing the page in pieces (as the committed layer draws in tiles
    /// and the live layer in dirty tiles) gives the pixels drawing it whole does, so the texture can't
    /// shimmer as a stroke grows or move when it's committed.
    @Test(.enabled(if: hasMetal, "needs a Metal device"))
    func drawingInPiecesMatchesDrawingWhole() throws {
        let page = page(of: [builtInStroke(.crayon, wave: 0), builtInStroke(.crayon, wave: 1)])
        let whole = try #require(render(page))
        let pieces = try #require(render(page, bands: [0 ..< 97, 97 ..< 203, 203 ..< 320]))
        let diff = try #require(compare(whole, pieces))
        #expect(diff.maxChannelDelta <= 1, "max channel delta \(diff.maxChannelDelta)")
    }

    @Test(.enabled(if: hasMetal, "needs a Metal device"))
    func theGrainStaysPutWhenTheStrokeMoves() throws {
        // Ink moved by a whole number of tooth cells isn't the same pixels: the paper didn't move with it.
        let stroke = builtInStroke(.crayon, wave: 3)
        var moved = stroke
        moved.points = moved.points.map {
            var p = $0
            p.location.y += 40
            return p
        }
        let a = try #require(coverage(render(page(of: [stroke])), rows: 100 ..< 160))
        let b = try #require(coverage(render(page(of: [moved])), rows: 180 ..< 240))
        #expect(a.inked > 0 && b.inked > 0)
        #expect(a.mask != b.mask)
    }

    @Test(.enabled(if: hasMetal, "needs a Metal device"))
    func paperShowsThroughAndPressureLaysMoreWax() throws {
        // The middle of the stroke: the nib is 9 pt wide, 18 px at 2×.
        let firm = try #require(coverage(render(page(of: [straight(force: 1)])), rows: 156 ..< 164))
        let light = try #require(coverage(render(page(of: [straight(force: 0.1)])), rows: 156 ..< 164))
        #expect(firm.meanAlpha > light.meanAlpha * 1.15, "firm \(firm.meanAlpha), light \(light.meanAlpha)")
        #expect(firm.meanAlpha > 0.6)
        // Wax, not a solid fill: some paper shows even under a firm press, and more under a light one.
        #expect(firm.bare > 0.003, "firm bare \(firm.bare)")
        #expect(light.bare > firm.bare)
    }

    /// A real crayon fills the paper in as strokes are layered: each stroke's own grain misses different
    /// bits of paper. The same grain twice only darkens the wax it already laid, so its holes stay.
    @Test(.enabled(if: hasMetal, "needs a Metal device"))
    func layeringStrokesFillsInThePaper() throws {
        let first = straight(force: 0.35)
        func copy(after seconds: TimeInterval) -> Stroke {
            Stroke(id: UUID(), color: first.color, brush: first.brush, points: first.points,
                   createdAt: first.createdAt.addingTimeInterval(seconds))
        }
        let second = copy(after: 3)
        let rows = 156 ..< 164
        let once = try #require(coverage(render(page(of: [first])), rows: rows))
        let same = try #require(coverage(render(page(of: [first, copy(after: 0)])), rows: rows))
        let layered = try #require(coverage(render(page(of: [first, second])), rows: rows))
        #expect(layered.bare < same.bare * 0.75, "layered \(layered.bare), same grain \(same.bare)")
        #expect(layered.bare < once.bare * 0.6, "layered \(layered.bare), once \(once.bare)")
        #expect(layered.meanAlpha > once.meanAlpha)
        // The paper's deepest pits stay bare in both: they share the paper's tooth.
        #expect(layered.bare > 0)
    }

    /// Scribbling back over ink in one stroke fills it in too: the crayon's texture turns with the
    /// direction of travel.
    @Test(.enabled(if: hasMetal, "needs a Metal device"))
    func goingBackOverInkFillsInThePaper() throws {
        let rows = 156 ..< 164
        let there = straight(force: 0.35, from: 20, to: 280)
        var andBack = there
        let back = straight(force: 0.35, from: 280, to: 20).points.dropFirst().map {
            var p = $0
            p.timestamp += 60.0 / 240
            return p
        }
        andBack.points += back
        let once = try #require(coverage(render(page(of: [there])), rows: rows))
        let twice = try #require(coverage(render(page(of: [andBack])), rows: rows))
        #expect(twice.bare < once.bare * 0.75, "there and back \(twice.bare), there \(once.bare)")
    }

    /// The live layer bakes a crayon stroke's settled pressure on the GPU and adds the hot stamps each frame,
    /// asynchronously, redrawing only the dirty part of each tile. What it shows when the stroke ends must be what the
    /// committed layer draws, or the ink would change when the Pencil lifts.
    /// `landEvery`: the GPU's wax comes back, and tiles redraw, every so many points while the stroke is
    /// still being drawn, as on device, where a tile's wax often lands after the Pencil has moved on. Tiles
    /// the stroke has left then redraw after new chunks that reach them have settled; those chunks must
    /// still reach the tiles' fields, or later wax there has holes.
    @Test(.enabled(if: hasMetal, "needs a Metal device"), arguments: [0, 1, 8, 30])
    func theLiveLayerShowsWhatIsCommitted(landEvery: Int) async throws {
        let transform = ViewTransform(scale: 1.5, offset: CGPoint(x: 10, y: 6))
        let view = LiveInkView(frame: CGRect(x: 0, y: 0, width: 480, height: 260))
        view.traitOverrides.displayScale = 2
        view.layoutIfNeeded()
        view.settle(at: transform)
        let source = builtInStroke(.crayon, wave: 2) // a loop, so it crosses its own baked chunks
        let live = LiveStroke(stroke: Stroke(id: source.id, color: source.color, brush: source.brush, points: []))
        view.entries = { [LiveInkView.Entry(stroke: live, previewFill: nil)] }
        for (i, point) in source.points.enumerated() {
            live.append(point, minSpacing: 0)
            view.invalidate(canvasRect: live.advance(predicted: []))
            view.displayPendingTiles()
            if landEvery > 0, i % landEvery == 0 {
                // Let the GPU's completions land on the main queue, then draw the tiles they marked.
                try await Task.sleep(nanoseconds: 3_000_000)
                view.displayPendingTiles()
            }
        }
        view.invalidate(canvasRect: live.geometry().bounds)
        // The wax comes back from the GPU on the main queue.
        let deadline = Date(timeIntervalSinceNow: 10)
        while view.rasterWorkPending, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(!view.rasterWorkPending)
        view.displayPendingTiles()
        #expect(live.bakeableChunkCount > 4)

        func image(_ draw: (CGContext) -> Void) -> CGImage? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: 960, height: 520, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.translateBy(x: 0, y: 520)
            ctx.scaleBy(x: 2, y: -2)
            draw(ctx)
            return ctx.makeImage()
        }
        let shown = try #require(image { view.layer.render(in: $0) })
        let committed = try #require(image { ctx in
            ctx.concatenate(transform.affine)
            let geometry = live.geometry()
            StrokeRenderer.draw(runs: geometry.runs, clip: geometry.bounds.insetBy(dx: -2, dy: -2),
                                brush: live.stroke.brush, color: live.stroke.color, in: ctx)
        })
        let bytes = try #require(rgbaBytes(shown))
        #expect(stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 128 }.count > 5000)
        let diff = try #require(compare(shown, committed))
        #expect(diff.maxChannelDelta <= 2, "max channel delta \(diff.maxChannelDelta)")
        #expect(diff.differingPixels <= 40, "\(diff.differingPixels) pixels differ")
    }

    /// Without Metal the crayon's paths are filled with the grain pattern of the same parameters.
    @Test func withoutMetalItFallsBackToTheGrainPattern() throws {
        let fill = StrokeRenderer.fillColor(for: .crayon, color: RGBA(r: 0, g: 0, b: 0), alpha: 1)
        #expect(fill.pattern != nil)
        let stroke = builtInStroke(.crayon, wave: 3)
        let geometry = StrokeRenderer.geometry(for: stroke)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 600, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: 320)
        ctx.scaleBy(x: 2, y: -2)
        PencilTexture.prepareContext(ctx)
        StrokeRenderer.fillPaths(runs: geometry.runs, clip: geometry.bounds, brush: stroke.brush, color: stroke.color,
                                 in: ctx)
        let image = try #require(ctx.makeImage())
        let bytes = try #require(rgbaBytes(image))
        let inked = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count
        #expect(inked > 2000)
    }

    // MARK: Helpers

    /// A straight crayon stroke across the page at y 80, the same width at any pressure, to compare the wax
    /// alone.
    private func straight(force: CGFloat, from start: CGFloat = 20, to end: CGFloat = 280) -> Stroke {
        var even = BrushDescriptor.crayon
        even.pressure = .init(amount: 0)
        let points = (0 ..< 60).map { i in
            StrokePoint(location: CGPoint(x: start + (end - start) * CGFloat(i) / 59, y: 80), force: force,
                        altitude: .pi / 2, azimuth: 0, timestamp: Double(i) / 240)
        }
        return Stroke(id: UUID(), color: RGBA(r: 0.1, g: 0.2, b: 0.6), brush: even, points: points,
                      createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    private func page(of strokes: [Stroke]) -> PageSnapshot {
        let doc = CanvasDocument(pageSize: PageSize(width: 300, height: 160))
        for stroke in strokes {
            doc.add(stroke)
        }
        return doc.snapshot()
    }

    /// The page's ink at 2× on white, drawn whole or one band of rows (top-down pixel rows) at a time.
    private func render(_ page: PageSnapshot, bands: [Range<Int>]? = nil) -> CGImage? {
        let width = 600, height = 320
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 2, y: -2)
        for band in bands ?? [0 ..< height] {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: CGFloat(band.lowerBound) / 2, width: 300, height: CGFloat(band.count) / 2))
            PageRenderer.drawInk(page, in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private struct Coverage {
        var meanAlpha: Double // over the rows, 0…1
        var bare: Double // share of pixels with under half the ink: paper showing through
        var inked: Int
        var mask: [Bool]
    }

    /// How much ink there is in `rows` (top-down), from how far each pixel is from white.
    private func coverage(_ image: CGImage?, rows: Range<Int>) -> Coverage? {
        guard let image, let bytes = rgbaBytes(image) else { return nil }
        var total = 0.0, bare = 0, inked = 0, mask: [Bool] = []
        // Only columns the ink spans, away from the round ends.
        let columns = 80 ..< 520
        for y in rows {
            for x in columns {
                let p = (y * image.width + x) * 4
                let darkness = 1 - Double(min(bytes[p], bytes[p + 1], bytes[p + 2])) / 255
                total += darkness
                bare += darkness < 0.45 ? 1 : 0
                inked += darkness > 0.5 ? 1 : 0
                mask.append(darkness > 0.5)
            }
        }
        let count = Double(rows.count * columns.count)
        return Coverage(meanAlpha: total / count, bare: Double(bare) / count, inked: inked, mask: mask)
    }
}
