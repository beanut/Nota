import UIKit

/// The committed ink on screen, as tiles cut from the renders of the canvas's bitmap.
///
/// Zoomed in in continuous scrolling, a page's canvas covers the screen and its overscan (about 17
/// megapixels on a 13-inch iPad), and it moves along the page as the view pans: every quarter screen or so
/// it renders again, a little further on. Shown as one image, each of those renders handed Core Animation a
/// new 70 MB image, which it copies on the main thread: a dropped frame or two, several times a second.
///
/// Tiles are laid out on the page, not on the canvas. Two renders at the same scale whose pixels line up
/// with the page the same way (a canvas moved by whole points does) share a grid, so a tile from one is
/// the same as from the other: a render after the canvas moved replaces only the tiles that weren't
/// already shown whole (`keptKeys`), and the tiles that were stay as they are. A render whose ink changed,
/// or at another scale, replaces them all.
final class CommittedInkTiles {
    /// Tile edge in pixels: 512 is 256 points at 2×, 1 MB a tile.
    static let tilePixels = 512

    struct Key: Hashable {
        let col: Int, row: Int
    }

    /// How a render's pixels line up with the page: its scale, and where the page's origin falls in its
    /// pixels (`anchor`, in whole pixels; `phase`, the fraction left over). Renders with the same `grid`
    /// share a pixel grid on the page.
    /// A render's scale and where the page's origin falls between its pixels: renders with the same grid
    /// share a pixel grid on the page.
    struct Grid: Equatable {
        let inkScale: CGFloat
        let pixelScale: CGFloat
        let phase: CGPoint

        static func == (a: Grid, b: Grid) -> Bool {
            a.inkScale == b.inkScale && a.pixelScale == b.pixelScale
                && abs(a.phase.x - b.phase.x) < 0.01 && abs(a.phase.y - b.phase.y) < 0.01
        }
    }

    struct Placement: Equatable {
        let grid: Grid
        let anchorX: Int, anchorY: Int

        init(transform: ViewTransform, pixelScale: CGFloat) {
            let x = transform.offset.x * pixelScale, y = transform.offset.y * pixelScale
            anchorX = Int(x.rounded())
            anchorY = Int(y.rounded())
            grid = Grid(inkScale: transform.scale, pixelScale: pixelScale,
                        phase: CGPoint(x: x - CGFloat(anchorX), y: y - CGFloat(anchorY)))
        }

        /// Where the tiles' origin (the page's, in whole pixels) is in the render, in points.
        var anchorPoint: CGPoint {
            CGPoint(x: CGFloat(anchorX) / grid.pixelScale, y: CGFloat(anchorY) / grid.pixelScale)
        }
    }

    /// One tile cut from a render: its pixels, and where they go in the tiles' pixel space.
    struct Cut {
        let key: Key
        let image: CGImage
        let pixelRect: CGRect
        /// The tile is whole: the render covered all of it.
        let isWhole: Bool
    }

    /// What a render shows: the tiles cut from it, and where its pixels were (the tiles' pixel space).
    struct Update {
        let placement: Placement
        let cuts: [Cut]
        let pixelRect: CGRect
        /// The other tiles inside `pixelRect` are kept, as they are. Otherwise every tile not in `cuts`
        /// goes; a render whose ink changed (or that's at another scale) passes false.
        let keepsOthers: Bool
    }

    // MARK: Cutting (on the render queue)

    /// Cuts the tiles of `ctx`, a bitmap drawn at `placement`, except `skipping`; with `within`, only
    /// those under that rect (the bitmap's pixels, top-left origin).
    static func cut(_ ctx: CGContext, placement: Placement, within: CGRect? = nil,
                    skipping: Set<Key> = []) -> [Cut] {
        guard let source = ctx.data, ctx.width > 0, ctx.height > 0,
              let space = ctx.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let t = tilePixels
        let image = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        guard let area = (within.map { $0.integral.intersection(image) } ?? image).nilIfEmpty else { return [] }
        let ax = placement.anchorX, ay = placement.anchorY
        let cols = floorDiv(Int(area.minX) - ax, t) ... floorDiv(Int(area.maxX) - 1 - ax, t)
        let rows = floorDiv(Int(area.minY) - ay, t) ... floorDiv(Int(area.maxY) - 1 - ay, t)
        let bytesPerPixel = ctx.bitsPerPixel / 8
        var cuts: [Cut] = []
        for row in rows {
            for col in cols {
                let key = Key(col: col, row: row)
                guard !skipping.contains(key) else { continue }
                let tile = CGRect(x: col * t + ax, y: row * t + ay, width: t, height: t)
                guard let part = tile.intersection(image).nilIfEmpty else { continue }
                let x0 = Int(part.minX), y0 = Int(part.minY), w = Int(part.width), h = Int(part.height)
                guard let tileCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: ctx.bitsPerComponent,
                                              bytesPerRow: 0, space: space, bitmapInfo: ctx.bitmapInfo.rawValue),
                    let destination = tileCtx.data
                else { continue }
                for y in 0 ..< h {
                    memcpy(destination + y * tileCtx.bytesPerRow,
                           source + (y0 + y) * ctx.bytesPerRow + x0 * bytesPerPixel, w * bytesPerPixel)
                }
                guard let cutImage = tileCtx.makeImage() else { continue }
                cuts.append(Cut(key: key, image: cutImage, pixelRect: part.offsetBy(dx: CGFloat(-ax), dy: CGFloat(-ay)),
                                isWhole: part.size == tile.size))
            }
        }
        return cuts
    }

    /// The render's pixels in the tiles' pixel space.
    static func pixelRect(of ctx: CGContext, placement: Placement) -> CGRect {
        CGRect(x: -placement.anchorX, y: -placement.anchorY, width: ctx.width, height: ctx.height)
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    // MARK: Showing (on the main thread)

    /// Holds the tiles. Laid out in the tiles' points: the page's origin (in whole pixels) is at zero.
    let host: CALayer
    private var tiles: [Key: (layer: CALayer, isWhole: Bool)] = [:]
    private(set) var grid: Grid?

    init(host: CALayer) {
        self.host = host
    }

    var tileCount: Int {
        tiles.count
    }

    /// The tiles a render at `placement` needn't cut: the whole ones already shown on its grid.
    func keptKeys(for placement: Placement) -> Set<Key> {
        guard placement.grid == grid else { return [] }
        return Set(tiles.compactMap { $0.value.isWhole ? $0.key : nil })
    }

    /// Whether `update` can be shown on top of what's shown: it's on the same grid.
    func canPatch(with placement: Placement) -> Bool {
        placement.grid == grid
    }

    func show(_ update: Update) {
        let scale = update.placement.grid.pixelScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if !update.keepsOthers || update.placement.grid != grid {
            let cutKeys = Set(update.cuts.map(\.key))
            for (key, tile) in tiles where !cutKeys.contains(key) {
                tile.layer.removeFromSuperlayer()
                tiles[key] = nil
            }
        } else {
            // Tiles the render no longer reaches: the canvas moved on.
            for (key, tile) in tiles where !tile.layer.frame.applying(.init(scaleX: scale, y: scale))
                .insetBy(dx: 0.5, dy: 0.5).intersects(update.pixelRect) {
                tile.layer.removeFromSuperlayer()
                tiles[key] = nil
            }
        }
        grid = update.placement.grid
        for cut in update.cuts {
            let layer = tiles[cut.key]?.layer ?? makeTile()
            layer.contents = cut.image
            layer.contentsScale = scale
            layer.frame = CGRect(x: cut.pixelRect.minX / scale, y: cut.pixelRect.minY / scale,
                                 width: cut.pixelRect.width / scale, height: cut.pixelRect.height / scale)
            tiles[cut.key] = (layer, cut.isWhole)
        }
    }

    func removeAll() {
        for tile in tiles.values {
            tile.layer.removeFromSuperlayer()
        }
        tiles.removeAll()
        grid = nil
    }

    private func makeTile() -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        host.addSublayer(layer)
        return layer
    }
}

private extension CGRect {
    var nilIfEmpty: CGRect? {
        isNull || isEmpty ? nil : self
    }
}
