import CoreGraphics
import Foundation
@testable import InkKit
import Testing

/// The points of `path`'s elements, in order, with a marker for each close.
private func elements(of path: CGPath) -> [CGPoint?] {
    var out: [CGPoint?] = []
    path.applyWithBlock { e in
        switch e.pointee.type {
        case .moveToPoint, .addLineToPoint: out.append(e.pointee.points[0])
        case .closeSubpath: out.append(nil)
        default: out.append(CGPoint(x: CGFloat.nan, y: .nan))
        }
    }
    return out
}

/// The stroke drawn alone into a 1:1 bitmap of its bounds, at `pixelsPerPoint`.
private func pixels(_ geometry: StrokeGeometry, _ stroke: Stroke, pixelsPerPoint: CGFloat) -> [UInt8] {
    let rect = geometry.bounds.insetBy(dx: -2, dy: -2).integral
    let width = Int(rect.width * pixelsPerPoint), height = Int(rect.height * pixelsPerPoint)
    let ctx = CommittedRenderer.makeBitmap(pixelSize: CGSize(width: width, height: height), scale: 1)!
    ctx.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
    ctx.translateBy(x: -rect.minX, y: -rect.minY)
    StrokeRenderer.fillPaths(runs: geometry.runs, clip: rect, brush: stroke.brush, color: stroke.color, in: ctx)
    let data = ctx.makeImage()!.dataProvider!.data! as Data
    return [UInt8](data)
}

/// Stroke geometry kept small and shared (NOT-108): `PackedGeometry`, the app's `GeometryCache` and a
/// page's `PageGeometry`.
@MainActor
struct GeometryCacheTests {
    private static let brushes = BrushDescriptor.bundled

    @Test(arguments: brushes)
    func packingKeepsTheOutlineWithinRounding(_ brush: BrushDescriptor) {
        for wave in 0 ..< 3 {
            let stroke = builtInStroke(brush, wave: wave)
            let built = StrokeRenderer.geometry(for: stroke)
            let packed = PackedGeometry(built)
            #expect(packed.isPacked)
            let unpacked = packed.unpacked()
            #expect(unpacked.bounds == built.bounds)
            #expect(unpacked.runs.count == built.runs.count)
            for (a, b) in zip(unpacked.runs, built.runs) {
                #expect(a.alpha == b.alpha)
                #expect(a.stamps.count == b.stamps.count)
                let pa = elements(of: a.path), pb = elements(of: b.path)
                #expect(pa.count == pb.count)
                let worst = zip(pa, pb).map { p, q -> CGFloat in
                    guard let p, let q else { return p == nil && q == nil ? 0 : .infinity }
                    return max(abs(p.x - q.x), abs(p.y - q.y))
                }.max() ?? 0
                #expect(worst <= 0.001, "\(brush.name) wave \(wave): a point moved \(worst) pt")
            }
        }
    }

    @Test func packingIsSeveralTimesSmallerAndDrawsTheSamePixels() {
        let stroke = builtInStroke(.pen, wave: 1)
        let built = StrokeRenderer.geometry(for: stroke)
        var points = 0
        for run in built.runs {
            run.path.applyWithBlock { _ in points += 1 }
        }
        let packed = PackedGeometry(built)
        // A CGPath holds 16 bytes a point at the least.
        #expect(packed.byteCount * 4 < points * 16)
        // At 12 pixels a point (6× zoom at 2×), rounding: a level in a few edge pixels, two in a handful.
        let a = pixels(built, stroke, pixelsPerPoint: 12), b = pixels(packed.unpacked(), stroke, pixelsPerPoint: 12)
        #expect(a.count == b.count)
        let diffs = zip(a, b).map { abs(Int($0) - Int($1)) }
        #expect(diffs.max() ?? 0 <= 2)
        #expect(diffs.filter { $0 > 0 }.count * 1000 < a.count)
        #expect(diffs.filter { $0 > 1 }.count < 10)
    }

    @Test func aPathPackingCantDescribeIsKeptAsItIs() {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let geometry = StrokeGeometry(runs: [StrokeRun(path: path, alpha: 1)], bounds: path.boundingBox)
        let packed = PackedGeometry(geometry)
        #expect(!packed.isPacked)
        #expect(packed.unpacked().runs[0].path === path)
    }

    @Test func theCacheLetsTheLeastRecentlyUsedGo() {
        let one = PackedGeometry(StrokeRenderer.geometry(for: builtInStroke(.pen, wave: 0)))
        let cache = GeometryCache(budget: one.byteCount * 2)
        let page = cache.makePage()
        let a = GeometryCache.Key(page: page, stroke: UUID()), b = GeometryCache.Key(page: page, stroke: UUID())
        let c = GeometryCache.Key(page: page, stroke: UUID())
        cache.store(one, for: a)
        cache.store(one, for: b)
        #expect(cache.packed(a) != nil) // a is now the most recently used
        cache.store(one, for: c)
        #expect(cache.contains(a))
        #expect(!cache.contains(b))
        #expect(cache.contains(c))
        #expect(cache.byteCount <= one.byteCount * 2)
        cache.trim(to: 0)
        #expect(cache.count == 0)
        #expect(cache.byteCount == 0)
    }

    @Test func aPageRebuildsWhatTheCacheLetGo() {
        let stroke = builtInStroke(.pen, wave: 2)
        let cache = GeometryCache(budget: 1 << 20)
        let page = PageGeometry(cache: cache)
        let first = page.geometry(for: stroke)
        #expect(page.builtCount == 1)
        _ = page.geometry(for: stroke)
        #expect(page.builtCount == 1) // unpacked
        cache.trim(to: 0)
        #expect(!page.isKept(stroke.id))
        #expect(page.cachedBounds(stroke.id) == first.bounds) // bounds outlive the geometry
        _ = page.geometry(for: stroke)
        #expect(page.builtCount == 2)
        #expect(page.isKept(stroke.id))
    }

    @Test func theMostRecentlyDrawnIsKeptUnpackedToo() {
        let stroke = builtInStroke(.pen, wave: 1)
        let cache = GeometryCache(budget: 1 << 20, unpackedBudget: 1 << 20)
        let page = PageGeometry(cache: cache)
        let first = page.geometry(for: stroke)
        #expect(cache.unpackedByteCount > 0)
        #expect(page.geometry(for: stroke).runs[0].path === first.runs[0].path) // not unpacked again
        page.forget(stroke.id)
        #expect(cache.unpackedByteCount == 0)
        // Over the unpacked budget, it's still kept packed.
        let small = GeometryCache(budget: 1 << 20, unpackedBudget: 16)
        let other = PageGeometry(cache: small)
        _ = other.geometry(for: stroke)
        #expect(small.unpackedByteCount == 0)
        #expect(other.isKept(stroke.id))
    }

    @Test func aFillThatDoesntKeepUsesWhatsKeptAndAddsNothing() {
        let kept = builtInStroke(.pen, wave: 0), passing = builtInStroke(.pen, wave: 2)
        let page = PageGeometry(cache: GeometryCache(budget: 1 << 20, unpackedBudget: 1 << 20))
        _ = page.geometry(for: kept)
        _ = page.geometry(for: kept, keeps: false)
        _ = page.geometry(for: passing, keeps: false)
        #expect(page.builtCount == 2)
        #expect(page.isKept(kept.id))
        #expect(!page.isKept(passing.id))
        #expect(page.cachedBounds(passing.id) == nil)
    }

    @Test func geometryBuiltFromAStrokeChangedSinceIsntKept() {
        let stroke = builtInStroke(.pen, wave: 0)
        let page = PageGeometry(cache: GeometryCache(budget: 1 << 20))
        let snapshot = page.generation
        page.forget(stroke.id) // the stroke changed after the snapshot was taken
        _ = page.geometry(for: stroke, generation: snapshot)
        #expect(!page.isKept(stroke.id))
        _ = page.geometry(for: stroke, generation: page.generation)
        #expect(page.isKept(stroke.id))
        #expect(page.packed(for: stroke.id, asOf: snapshot) == nil)
    }

    @Test func aPageGoingLetsGoOfItsGeometry() {
        let cache = GeometryCache(budget: 1 << 20)
        var page: PageGeometry? = PageGeometry(cache: cache)
        _ = page?.geometry(for: builtInStroke(.pen, wave: 0))
        #expect(cache.count == 1)
        page = nil
        #expect(cache.count == 0)
    }

    @Test func aStrokeChangedInPlaceIsForgotten() {
        let document = CanvasDocument()
        let stroke = builtInStroke(.pen, wave: 0)
        document.add(stroke)
        _ = document.geometry.geometry(for: stroke)
        #expect(document.geometry.isKept(stroke.id))
        #expect(document.updatePoint(strokeID: stroke.id, index: 3) { $0.location.x += 5 })
        #expect(!document.geometry.isKept(stroke.id))
        #expect(document.geometry.cachedBounds(stroke.id) == nil)
    }
}
