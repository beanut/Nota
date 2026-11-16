import CoreGraphics
@testable import InkKit
import Testing
import UIKit

/// The committed ink is shown in tiles laid out on the page, so a render after the canvas moved along the
/// page replaces only the tiles it newly reaches.
@MainActor
@Suite("Committed ink tiles")
struct CommittedInkTilesTests {
    private let t = CommittedInkTiles.tilePixels

    /// A bitmap `width` × `height` pixels whose every pixel says where it is on the page: its blue byte is
    /// its page column's tile, its green byte its page row's tile (see `pageTile`).
    private func render(width: Int, height: Int, at placement: CommittedInkTiles.Placement) throws -> CGContext {
        let ctx = try #require(CommittedRenderer.makeBitmap(pixelSize: CGSize(width: width, height: height), scale: 1))
        let data = try #require(ctx.data)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let p = data + y * ctx.bytesPerRow + x * 4
                p.storeBytes(of: UInt8(truncatingIfNeeded: pageTile(x - placement.anchorX)), as: UInt8.self)
                p.storeBytes(of: UInt8(truncatingIfNeeded: pageTile(y - placement.anchorY)), toByteOffset: 1, as: UInt8.self)
                p.storeBytes(of: 0, toByteOffset: 2, as: UInt8.self)
                p.storeBytes(of: 255, toByteOffset: 3, as: UInt8.self)
            }
        }
        return ctx
    }

    private func pageTile(_ pixel: Int) -> Int {
        Int((Double(pixel) / Double(t)).rounded(.down)) + 100
    }

    private func placement(x: CGFloat, y: CGFloat) -> CommittedInkTiles.Placement {
        CommittedInkTiles.Placement(transform: ViewTransform(scale: 3, offset: CGPoint(x: x, y: y)), pixelScale: 2)
    }

    @Test func tilesAreCutOnThePageNotTheRender() throws {
        // The page's origin is 300.5 pt left of the render's: 601 px.
        let placement = placement(x: -300.5, y: 0)
        #expect(placement.anchorX == -601)
        let ctx = try render(width: 1200, height: 100, at: placement)
        let cuts = CommittedInkTiles.cut(ctx, placement: placement)
        // Page pixels 601 ..< 1801: tiles 1 (from 601, partial), 2 and 3 (to 1801, partial).
        #expect(cuts.map(\.key.col).sorted() == [1, 2, 3])
        let first = try #require(cuts.first { $0.key.col == 1 })
        #expect(first.pixelRect == CGRect(x: 601, y: 0, width: 2 * t - 601, height: 100))
        #expect(!first.isWhole)
        // Each tile holds the page's pixels for it.
        for cut in cuts {
            let bytes = try #require(cut.image.dataProvider?.data as Data?)
            #expect(bytes[0] == UInt8(cut.key.col + 100))
            #expect(bytes[bytes.count - cut.image.bytesPerRow] == UInt8(cut.key.col + 100))
        }
    }

    @Test func aRenderAfterTheCanvasMovedKeepsTheTilesAlreadyShownWhole() throws {
        let tiles = CommittedInkTiles(host: CALayer())
        let before = placement(x: 0, y: 0)
        let first = try render(width: 3 * t, height: t, at: before)
        tiles.show(.init(placement: before, cuts: CommittedInkTiles.cut(first, placement: before),
                         pixelRect: CommittedInkTiles.pixelRect(of: first, placement: before), keepsOthers: false))
        #expect(tiles.tileCount == 3)

        // The canvas moved one tile along the page, by whole points: the same pixel grid.
        let after = placement(x: -CGFloat(t) / 2, y: 0)
        #expect(tiles.canPatch(with: after))
        let kept = tiles.keptKeys(for: after)
        #expect(kept == [.init(col: 0, row: 0), .init(col: 1, row: 0), .init(col: 2, row: 0)])
        let second = try render(width: 3 * t, height: t, at: after)
        let cuts = CommittedInkTiles.cut(second, placement: after, skipping: kept)
        #expect(cuts.map(\.key) == [.init(col: 3, row: 0)]) // only the tile it newly reaches
        tiles.show(.init(placement: after, cuts: cuts,
                         pixelRect: CommittedInkTiles.pixelRect(of: second, placement: after), keepsOthers: true))
        #expect(tiles.tileCount == 3) // the tile it no longer reaches is gone
        #expect(tiles.keptKeys(for: after) == [.init(col: 1, row: 0), .init(col: 2, row: 0), .init(col: 3, row: 0)])
    }

    @Test func anotherScaleOrPixelGridKeepsNothing() throws {
        let tiles = CommittedInkTiles(host: CALayer())
        let before = placement(x: 0, y: 0)
        let ctx = try render(width: t, height: t, at: before)
        tiles.show(.init(placement: before, cuts: CommittedInkTiles.cut(ctx, placement: before),
                         pixelRect: CommittedInkTiles.pixelRect(of: ctx, placement: before), keepsOthers: false))
        let between = placement(x: 0.25, y: 0) // half a pixel along
        #expect(!tiles.canPatch(with: between))
        #expect(tiles.keptKeys(for: between).isEmpty)
        let zoomed = CommittedInkTiles.Placement(transform: ViewTransform(scale: 4, offset: .zero), pixelScale: 2)
        #expect(tiles.keptKeys(for: zoomed).isEmpty)
    }

    @Test func aStrokeReplacesOnlyTheTilesUnderIt() throws {
        let placement = placement(x: 0, y: 0)
        let ctx = try render(width: 3 * t, height: 2 * t, at: placement)
        let cuts = CommittedInkTiles.cut(ctx, placement: placement, within: CGRect(x: t + 10, y: 10, width: 20, height: 20))
        #expect(cuts.map(\.key) == [.init(col: 1, row: 0)])
    }
}
