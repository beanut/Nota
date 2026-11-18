import CoreGraphics
import Foundation

// MARK: - Template

/// Everything needed to draw one page's template, and the tiles it's drawn into (NOT-109).
struct TemplatePaper: Equatable {
    var template = PageTemplate.default
    var artwork: TemplateArtwork?
    var palette = PaperPalette.standard(.white)
    var pageSize = PageSize.default

    static func == (a: TemplatePaper, b: TemplatePaper) -> Bool {
        a.template == b.template && a.artwork === b.artwork && a.palette == b.palette && a.pageSize == b.pageSize
    }

    /// Whether there's anything to draw over the paper colour.
    var isPlain: Bool {
        template.isPlain
    }

    /// Draws the template into `ctx` (addressed in page points), limited to `rect` (page points), at
    /// `pixelsPerPoint`: lines are never thinner than a pixel. With `fillsPaper`, the paper colour first.
    func draw(in ctx: CGContext, rect: CGRect, pixelsPerPoint: CGFloat, fillsPaper: Bool = false) {
        TemplateRenderer.draw(template, pageSize: pageSize, palette: palette, artwork: artwork, in: ctx,
                              visibleRect: rect, minimumLineWidth: 1 / max(pixelsPerPoint, 1e-6), fillsPaper: fillsPaper)
    }

    /// Names a paper's tiles in the `TileCache`: one name for every page drawn on the same template, paper,
    /// size and artwork, so pages of a lined note share their template tiles.
    private struct Key: Hashable {
        let template: PageTemplate
        let artwork: UUID?
        let pageSize: PageSize
        let colors: [[CGFloat]]
    }

    @MainActor private static var cacheIDs: [Key: UUID] = [:]

    /// The template's tile content, or nil when it's plain (the paper colour alone, which the page layer shows).
    @MainActor
    func tileContent() -> VectorTileContent? {
        guard !isPlain else { return nil }
        let key = Key(template: template, artwork: artwork?.id, pageSize: pageSize,
                      colors: [palette.surface, palette.rule, palette.accent, palette.label].map { $0.components ?? [] })
        let id: UUID
        if let known = Self.cacheIDs[key] {
            id = known
        } else {
            id = UUID()
            Self.cacheIDs[key] = id
        }
        let paper = self
        var content = VectorTileContent(cacheID: id, version: 0, pageBounds: pageSize.bounds, changes: VectorChangeLog(),
                                        drawnRects: nil) { ctx, rect, level in
            paper.draw(in: ctx, rect: rect, pixelsPerPoint: level.pixelsPerPoint)
        }
        content.drawsWhole = artwork != nil && template.background?.id == artwork?.id
        return content
    }
}

extension TemplatePaper: @unchecked Sendable {} // values; `TemplateArtwork` and the palette's colours are immutable

// MARK: - Objects

/// What a page's object layer (or its tape layer) last put in its tiles, kept by the page so every canvas
/// that shows it labels tiles the same way (NOT-109): the objects, the version they're at, and which page
/// rect each change touched. Tiles of the page drawn at an older version are still current outside the
/// changes since.
@MainActor
final class ObjectTileHistory {
    /// Names the layer's tiles in the `TileCache`.
    nonisolated let cacheID = UUID()
    private(set) var version = 0
    private(set) var objects: [any PageObject] = []
    private var pageBounds = CGRect.null
    private var changes = VectorChangeLog()

    deinit {
        TileCache.shared.removeAll(page: cacheID)
    }

    /// The tiles' content for `objects` (lowest `zIndex` first) on a page of `pageBounds`, a new version
    /// if they differ from the last objects given; nil when there are none.
    func content(for objects: [any PageObject], pageBounds: CGRect) -> VectorTileContent? {
        let touched: CGRect
        if pageBounds != self.pageBounds {
            touched = pageBounds.union(self.pageBounds)
            self.pageBounds = pageBounds
        } else {
            touched = ObjectDiff.touched(from: self.objects, to: objects)
        }
        self.objects = objects
        if !touched.isNull {
            bump(touched)
        }
        return content
    }

    /// The objects in `rect` look different though they're the same (a picture they draw finished decoding):
    /// their tiles are drawn again.
    func invalidate(_ rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        bump(rect)
    }

    /// The page rect the objects using any of `assets` reach (`.null` if none).
    func reach(ofObjectsUsing assets: Set<ImageAssetID>) -> CGRect {
        objects.reduce(CGRect.null) { rect, object in
            guard let image = object as? ImageObject, assets.contains(image.asset) else { return rect }
            return rect.union(ObjectDiff.reach(of: image))
        }
    }

    private func bump(_ rect: CGRect) {
        version += 1
        changes.record(rect, version: version)
    }

    /// The current objects' tile content (nil when there are none).
    var content: VectorTileContent? {
        guard !objects.isEmpty else { return nil }
        let objects = objects, clip = pageBounds
        let reaches = objects.map(ObjectDiff.reach(of:))
        return VectorTileContent(cacheID: cacheID, version: version, pageBounds: pageBounds, changes: changes,
                                 drawnRects: reaches) { ctx, rect, _ in
            let reaching = zip(objects, reaches).compactMap { $1.intersects(rect) ? $0 : nil }
            guard !reaching.isEmpty else { return }
            // Pictures never hold a tile up: what's decoded is drawn, and the rest when it's ready.
            ImageDrawing.with(ImageDrawing.Options(defersDecoding: true)) {
                PageRenderer.draw(reaching, clip: clip, in: ctx)
            }
        }
    }
}

/// Where objects draw and what changed between two lists of them.
enum ObjectDiff {
    /// Every page point `object` may put a pixel on: its bounds, and for a shape its stroke and arrowhead
    /// around its outline; a little more for anti-aliasing.
    static func reach(of object: any PageObject) -> CGRect {
        if let shape = object as? ShapeObject {
            var t = shape.transform
            var rect = shape.outline().copy(using: &t)?.boundingBoxOfPath ?? shape.bounds
            let width = shape.drawnLineWidth
            if let head = shape.arrowHead(width: width) {
                for point in head {
                    rect = rect.union(CGRect(origin: point, size: .zero))
                }
            }
            return rect.insetBy(dx: -(width / 2 + 2), dy: -(width / 2 + 2))
        }
        let bounds = object.bounds
        guard !bounds.isNull else { return .null }
        return bounds.insetBy(dx: -4, dy: -4)
    }

    /// The page rect where `new` draws differently from `old` (both lowest `zIndex` first): objects added,
    /// removed, changed or restacked. `.null` when they draw the same.
    static func touched(from old: [any PageObject], to new: [any PageObject]) -> CGRect {
        var rect = CGRect.null
        var before: [UUID: any PageObject] = [:]
        for object in old {
            before[object.id] = object
        }
        var common: [UUID] = []
        for object in new {
            if let was = before.removeValue(forKey: object.id) {
                common.append(object.id)
                if !same(was, object) {
                    rect = rect.union(reach(of: was)).union(reach(of: object))
                }
            } else {
                rect = rect.union(reach(of: object))
            }
        }
        for object in before.values {
            rect = rect.union(reach(of: object))
        }
        // Objects that kept their place but changed order among each other: where they are is redrawn.
        let still = Set(common)
        let oldOrder = old.lazy.map(\.id).filter { still.contains($0) }
        if !oldOrder.elementsEqual(common) {
            let byID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (was, now) in zip(oldOrder, common) where was != now {
                if let object = byID[was] {
                    rect = rect.union(reach(of: object))
                }
                if let object = byID[now] {
                    rect = rect.union(reach(of: object))
                }
            }
        }
        return rect
    }

    /// Whether two objects draw the same: equal values of the same kind.
    static func same(_ a: any PageObject, _ b: any PageObject) -> Bool {
        guard let a = a as? any Equatable else { return false }
        return equal(a, b)
    }

    private static func equal<T: Equatable>(_ a: T, _ b: Any) -> Bool {
        (b as? T) == a
    }
}
