import QuartzCore
import UIKit

/// The tiles of one level on screen: a layer per tile with ink, its `CGImage` as contents, placed in the
/// level's own pixel grid. The grid layer's transform takes that grid to the view, so a pan or pinch moves
/// one layer, and settled at the level's own scale (and a pixel-aligned offset) a tile pixel is a screen pixel.
@MainActor
final class TileLayerGrid {
    let layer = CALayer()
    private(set) var level: TileLevel?
    private var tiles: [TileKey: CALayer] = [:]
    private var images: [TileKey: CGImage] = [:]
    private var spare: [CALayer] = []

    private static let noActions: [String: CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
        "transform": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()
    ]

    init() {
        layer.anchorPoint = .zero
        layer.actions = Self.noActions
    }

    /// The images shown, keyed by tile.
    var shownImages: [(key: TileKey, image: CGImage)] {
        images.map { ($0.key, $0.value) }
    }

    /// Shows exactly `shown` (tiles of `level` with ink), reusing layers, and returns whether any image
    /// changed. Call inside a transaction with actions disabled.
    @discardableResult
    func show(_ shown: [(key: TileKey, image: CGImage)], level: TileLevel, displayScale: CGFloat) -> Bool {
        var changed = false
        if self.level != level {
            changed = true
            clear()
            self.level = level
        }
        var keep = Set<TileKey>()
        let side = CGFloat(TileKey.side) / displayScale
        for (key, image) in shown {
            keep.insert(key)
            let tile: CALayer
            if let existing = tiles[key] {
                tile = existing
            } else {
                tile = spare.popLast() ?? Self.makeTileLayer()
                tile.isHidden = false
                tile.frame = CGRect(x: CGFloat(key.col) * side, y: CGFloat(key.row) * side, width: side, height: side)
                tile.contentsScale = displayScale
                if tile.superlayer == nil {
                    layer.addSublayer(tile)
                }
                tiles[key] = tile
            }
            if images[key] !== image {
                tile.contents = image
                images[key] = image
                changed = true
            }
        }
        for (key, tile) in tiles where !keep.contains(key) {
            recycle(tile)
            tiles[key] = nil
            images[key] = nil
            changed = true
        }
        return changed
    }

    private static func makeTileLayer() -> CALayer {
        let tile = CALayer()
        tile.anchorPoint = .zero
        tile.actions = noActions
        tile.isOpaque = false
        tile.magnificationFilter = .linear
        return tile
    }

    private func recycle(_ tile: CALayer) {
        tile.contents = nil
        tile.isHidden = true
        if spare.count < 32 {
            spare.append(tile)
        } else {
            tile.removeFromSuperlayer()
        }
    }

    func clear() {
        for tile in tiles.values {
            recycle(tile)
        }
        tiles.removeAll()
        images.removeAll()
        level = nil
    }

    /// Puts the grid where `transform` puts the page.
    func place(at transform: ViewTransform, displayScale: CGFloat) {
        guard let level, level.pixelsPerPoint > 0 else { return }
        let k = transform.scale * displayScale / level.pixelsPerPoint
        layer.setAffineTransform(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: transform.offset.x, ty: transform.offset.y))
    }
}
