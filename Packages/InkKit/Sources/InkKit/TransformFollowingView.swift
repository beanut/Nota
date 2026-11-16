import UIKit

/// A canvas layer drawn as vectors at the canvas's transform: the template (`TemplateView`) and the page's
/// objects (`ObjectLayerView`). Redrawing at each new scale keeps lines one crisp width at every zoom
/// instead of scaling a bitmap.
///
/// The view is as large as the canvas (the viewport and its overscan when zoomed in: about 17 megapixels on
/// a 13-inch iPad), so it's drawn in tiles (`tileSize`), laid out at the transform they were drawn at:
///  - **Moving without zooming** moves the tiles. Only tiles the view newly reaches are drawn, so a canvas
///    moving along a zoomed-in page in continuous scrolling draws a strip, not 17 megapixels, and a pan
///    draws nothing once the page in view is covered. It's drawn again when it comes to rest off the pixel
///    grid it was drawn on.
///  - **Zooming** needs every tile drawn again. A redraw that takes a good part of a frame (a page of
///    pictures, a dense template) on every frame of a pinch is what makes zooming stutter, so the view
///    paces itself by what its last draw cost: a cheap draw (`cheapDraw`) still happens every frame, while
///    a dearer one rests for `restPerDraw` times as long as it took, and in between the tiles scale with
///    the canvas, which costs nothing. It always catches up: when the rest is over (even if the canvas has
///    stopped changing by then), and at once when the movement ends.
class TransformFollowingView: UIView {
    /// A draw this quick is done on every frame.
    static let cheapDraw: CFTimeInterval = 0.002
    /// How long a draw that isn't cheap rests before the next, as a multiple of the time it took, so
    /// drawing takes at most a tenth of the main thread while the canvas moves.
    static let restPerDraw: Double = 9
    /// Tile edge in points: 512 px at 2×, 1 MB a tile.
    static let tileSize: CGFloat = 256
    /// Zoomed out this far from where it was drawn (in area), the view is drawn again rather than tiled
    /// further at the old scale.
    static let maxTiledArea: CGFloat = 4

    /// Where the canvas is.
    private var canvasTransform = ViewTransform()
    /// The transform the tiles are drawn at (or will be, at the next display).
    private(set) var drawnTransform = ViewTransform()
    /// No redraw before this, while the canvas is zooming.
    private var restsUntil: CFTimeInterval = 0
    /// What the tiles drawn since the view last moved took.
    private var drawCost: CFTimeInterval = 0
    private var catchUp: Timer?

    private struct TileKey: Hashable {
        let col: Int, row: Int
    }

    /// Holds the tiles, laid out where they were drawn (`drawnTransform`), and moved and scaled to the canvas.
    private let tileHost = CALayer()
    private var tiles: [TileKey: Tile] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Tiles reach past the view's edges to the next tile boundary.
        clipsToBounds = true
        layer.anchorPoint = .zero
        tileHost.anchorPoint = .zero
        tileHost.actions = ["sublayers": NSNull(), "transform": NSNull()]
        layer.addSublayer(tileHost)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        catchUp?.invalidate()
    }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            if isHidden {
                removeAllTiles()
            } else {
                redraw()
            }
        }
    }

    /// Covers `rect` of the superview. Used instead of `frame`, which means nothing while the view is
    /// transformed.
    func fill(_ rect: CGRect) {
        let size = CGRect(origin: .zero, size: rect.size)
        if bounds != size {
            bounds = size
            updateTiles() // the part newly covered
        }
        if center != rect.origin {
            center = rect.origin
        }
    }

    /// Follows the canvas to `transform`. `moving` while a pan or zoom is under way: a redraw at a new scale
    /// may then be put off (see the type's comment). Without it the view is sharp at `transform` now.
    func follow(_ transform: ViewTransform, moving: Bool = false) {
        canvasTransform = transform
        drawCost = 0
        guard transform != drawnTransform, !isHidden else {
            if transform == drawnTransform {
                place()
            } else {
                redraw()
            }
            return
        }
        if transform.scale == drawnTransform.scale, moving || isWholePixelShift(from: drawnTransform, to: transform) {
            place()
        } else if !moving || CACurrentMediaTime() >= restsUntil {
            redraw()
        } else {
            place()
            scheduleCatchUp()
        }
    }

    /// Draws every tile again, at the canvas's transform. Subclasses call this, not `setNeedsDisplay()`.
    func redraw() {
        catchUp?.invalidate()
        catchUp = nil
        drawnTransform = canvasTransform
        place()
        for tile in tiles.values {
            tile.setNeedsDisplay()
        }
    }

    /// Moves the tiles from where they were drawn to where the canvas is now, and draws the ones it newly
    /// needs.
    private func place() {
        let t = shownTransform(drawnAt: drawnTransform)
        if tileHost.affineTransform() != t {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tileHost.setAffineTransform(t)
            CATransaction.commit()
        }
        updateTiles()
    }

    private func shownTransform(drawnAt from: ViewTransform) -> CGAffineTransform {
        let to = canvasTransform
        guard from != to, from.scale > 0 else { return .identity }
        let k = to.scale / from.scale
        return CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: to.offset.x - from.offset.x * k,
                                 ty: to.offset.y - from.offset.y * k)
    }

    /// The tiles move with the canvas: `drawnTransform` to the canvas's.
    var shownTransform: CGAffineTransform {
        tileHost.affineTransform()
    }

    /// Whether `to` is `from` moved by whole pixels, so tiles drawn at `from` are as sharp at `to`.
    private func isWholePixelShift(from: ViewTransform, to: ViewTransform) -> Bool {
        let scale = tileScale
        func whole(_ d: CGFloat) -> Bool {
            abs(d * scale - (d * scale).rounded()) < 0.01
        }
        return from.scale == to.scale && whole(to.offset.x - from.offset.x) && whole(to.offset.y - from.offset.y)
    }

    /// Makes the tiles that cover the view (in the space they're drawn in) and lets go of the others.
    private func updateTiles() {
        guard !isHidden, bounds.width > 0, bounds.height > 0 else {
            removeAllTiles()
            return
        }
        let needed = bounds.applying(tileHost.affineTransform().inverted())
        guard needed.width * needed.height <= bounds.width * bounds.height * Self.maxTiledArea else {
            // Zoomed far out from where it was drawn: too many tiles at the old scale.
            if drawnTransform != canvasTransform {
                redraw()
            }
            return
        }
        let size = Self.tileSize
        let cols = Int((needed.minX / size).rounded(.down)) ... Int(((needed.maxX - 0.001) / size).rounded(.down))
        let rows = Int((needed.minY / size).rounded(.down)) ... Int(((needed.maxY - 0.001) / size).rounded(.down))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (key, tile) in tiles where !cols.contains(key.col) || !rows.contains(key.row) {
            tile.removeFromSuperlayer()
            tiles[key] = nil
        }
        for row in rows {
            for col in cols {
                let key = TileKey(col: col, row: row)
                guard tiles[key] == nil else { continue }
                let tile = Tile()
                tile.owner = self
                tile.anchorPoint = .zero
                tile.contentsScale = tileScale
                tile.frame = CGRect(x: CGFloat(col) * size, y: CGFloat(row) * size, width: size, height: size)
                tileHost.addSublayer(tile)
                tiles[key] = tile
                tile.setNeedsDisplay()
            }
        }
    }

    private func removeAllTiles() {
        guard !tiles.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in tiles.values {
            tile.removeFromSuperlayer()
        }
        CATransaction.commit()
        tiles.removeAll()
    }

    private var tileScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = tileScale
        for tile in tiles.values where tile.contentsScale != scale {
            tile.contentsScale = scale
            tile.setNeedsDisplay()
        }
    }

    /// Redraws once the rest is over, in case the canvas doesn't change again before the movement ends
    /// (scrolling moves an embedded page without changing its transform).
    private func scheduleCatchUp() {
        guard catchUp == nil else { return }
        let timer = Timer(timeInterval: max(restsUntil - CACurrentMediaTime(), 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.catchUp = nil
                if self.drawnTransform != self.canvasTransform {
                    self.redraw()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common) // also while a scroll is tracking
        catchUp = timer
    }

    /// Draws the contents in view space at `transform`, limited to `rect`.
    func drawContents(at _: ViewTransform, in _: CGRect, context _: CGContext) {}

    /// The tiles waiting to be drawn.
    var tilesNeedingDisplay: Int {
        tiles.values.filter { $0.needsDisplay() }.count
    }

    var tileCount: Int {
        tiles.count
    }

    /// Draws the tiles waiting to be drawn now rather than at the next Core Animation commit.
    func displayTiles() {
        for tile in tiles.values {
            tile.displayIfNeeded()
        }
    }

    /// One tile: its part of the view, drawn at `drawnTransform`. Times its whole display, not `draw(in:)`:
    /// Core Graphics may only record what `draw(in:)` asks for and do the work (resampling a picture, say)
    /// once it has returned, as the backing store is filled.
    private final class Tile: CALayer {
        weak var owner: TransformFollowingView?

        override func display() {
            let start = CACurrentMediaTime()
            super.display()
            let end = CACurrentMediaTime()
            owner?.tileDrew(taking: end - start, endingAt: end)
        }

        override func draw(in ctx: CGContext) {
            guard let owner else { return }
            ctx.translateBy(x: -frame.minX, y: -frame.minY)
            owner.drawContents(at: owner.drawnTransform, in: frame, context: ctx)
        }

        override func action(forKey _: String) -> CAAction? {
            nil
        }
    }

    private func tileDrew(taking duration: CFTimeInterval, endingAt end: CFTimeInterval) {
        drawCost += duration
        rest(afterDrawTaking: drawCost, endingAt: end)
    }

    /// A draw that took `duration` ended at `end`: sets how long the next one waits while the canvas zooms.
    func rest(afterDrawTaking duration: CFTimeInterval, endingAt end: CFTimeInterval = CACurrentMediaTime()) {
        restsUntil = duration <= Self.cheapDraw ? 0 : end + duration * Self.restPerDraw
    }
}
