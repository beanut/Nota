import CoreGraphics
import Foundation

/// How the editor shows a notebook's pages.
public enum PageLayoutMode: String, CaseIterable, Identifiable, Sendable {
    /// One page at a time, turned by swiping sideways.
    case paged
    /// Every page in one column, scrolled vertically.
    case continuous

    public var id: String {
        rawValue
    }

    /// For menus: "Horizontal" or "Vertical", after the direction the pages move.
    public var displayName: String {
        switch self {
        case .paged: "Horizontal"
        case .continuous: "Vertical"
        }
    }

    static let defaultsKey = "InkKit.pageLayout"

    /// The saved choice, or paged when there's none.
    static func load(from defaults: UserDefaults) -> PageLayoutMode {
        defaults.string(forKey: defaultsKey).flatMap(PageLayoutMode.init(rawValue:)) ?? .paged
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Where each page sits in continuous scrolling: one column, centred, with a gap between pages, at one
/// scale for every page so ink is the same size on all of them. The widest page fills the width between
/// the side margins. Frames are in the scroll content's points at zoom 1.
///
/// A pure value, cheap to rebuild: laying out 300 pages is a loop over their sizes, and finding the pages
/// in view is a binary search.
struct ContinuousPageLayout: Equatable {
    /// Content points per page point.
    let scale: CGFloat
    /// Each page's frame, top to bottom.
    let frames: [CGRect]
    /// The whole column, margins included.
    let contentSize: CGSize

    struct Insets: Equatable {
        var top: CGFloat
        var side: CGFloat
        var bottom: CGFloat
        var gap: CGFloat
    }

    /// Room for the navigation bar above the first page and the page bar below the last.
    static let defaultInsets = Insets(top: 24, side: 24, bottom: 76, gap: 16)

    init(pageSizes: [CGSize], width: CGFloat, insets: Insets = defaultInsets) {
        let widest = pageSizes.map(\.width).max() ?? 0
        let available = width - insets.side * 2
        guard widest > 0, available > 0 else {
            scale = 1
            frames = []
            contentSize = CGSize(width: max(width, 0), height: 0)
            return
        }
        let scale = available / widest
        var y = insets.top
        var frames: [CGRect] = []
        frames.reserveCapacity(pageSizes.count)
        for size in pageSizes {
            let w = size.width * scale, h = size.height * scale
            frames.append(CGRect(x: (width - w) / 2, y: y, width: w, height: h))
            y += h + insets.gap
        }
        self.scale = scale
        self.frames = frames
        contentSize = CGSize(width: width, height: y - insets.gap + insets.bottom)
    }

    /// The pages any part of which is inside `rect` (content points at zoom 1), top to bottom.
    func visiblePages(in rect: CGRect) -> Range<Int> {
        guard !frames.isEmpty, rect.height > 0 else { return 0 ..< 0 }
        // First page whose bottom is below the top of the rect.
        let first = firstIndex { $0.maxY > rect.minY }
        var last = first
        while last < frames.count, frames[last].minY < rect.maxY {
            last += 1
        }
        return first ..< last
    }

    /// The page at the middle of `rect`, or the one nearest it when the middle falls in a gap: the page
    /// being read, for the page number and the page bar.
    func currentPage(in rect: CGRect) -> Int? {
        guard !frames.isEmpty else { return nil }
        let y = rect.midY
        let i = firstIndex { $0.maxY > y }
        guard i < frames.count else { return frames.count - 1 }
        guard i > 0, frames[i].minY > y else { return i }
        // In the gap above page i: the closer of it and the page before.
        return y - frames[i - 1].maxY < frames[i].minY - y ? i - 1 : i
    }

    /// The content offset (zoom 1) that shows page `index` from its top, just under the top inset,
    /// clamped to the scrollable range for a view `viewportHeight` tall.
    func offset(showingPage index: Int, viewportHeight: CGFloat, topInset: CGFloat) -> CGFloat {
        guard frames.indices.contains(index) else { return 0 }
        let maxOffset = max(contentSize.height - viewportHeight, 0)
        return min(max(frames[index].minY - topInset, 0), maxOffset)
    }

    // MARK: Render windows

    /// How far a page's canvas reaches past the viewport on each side, as a fraction of the viewport.
    static let renderOverscan = CGSize(width: 0.25, height: 0.5)
    /// How close the viewport may come to the edge of a page's canvas, as a fraction of the viewport,
    /// before the canvas moves (and renders again) to keep ahead of it.
    static let renderMargin = CGSize(width: 0.125, height: 0.25)

    /// Where a page's canvas goes, in scroll content points at the current zoom: the part of `page` its
    /// ink is rendered for. Scrolling moves the canvas with the content, so the ink only renders again
    /// when the canvas moves or changes size, never just because the view scrolled.
    ///
    /// The window is the viewport plus `renderOverscan`, cut to the page, so a page that fits in that is
    /// covered whole and never renders again while scrolling. `current` is kept while it still covers the
    /// viewport plus `renderMargin`; otherwise the window centres on the viewport, inside the page.
    /// `keepingSize` (mid-pinch) keeps `current`'s size so the canvas doesn't make a new bitmap every frame.
    static func renderWindow(forPage page: CGRect, viewport: CGRect, current: CGRect?,
                             keepingSize: Bool = false) -> CGRect {
        let size: CGSize
        if keepingSize, let current {
            size = current.size
        } else {
            let o = renderOverscan
            size = CGSize(width: min(page.width, viewport.width * (1 + 2 * o.width)).rounded(.up),
                          height: min(page.height, viewport.height * (1 + 2 * o.height)).rounded(.up))
        }
        if let current, current.size == size {
            let m = renderMargin
            let needed = viewport.insetBy(dx: -viewport.width * m.width, dy: -viewport.height * m.height)
                .intersection(page)
            if needed.isNull || current.contains(needed) {
                return current
            }
        }
        func place(_ length: CGFloat, around centre: CGFloat, within lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            guard length < upper - lower else { return ((lower + upper - length) / 2).rounded() }
            return min(max((centre - length / 2).rounded(), lower.rounded(.up)), (upper - length).rounded(.down))
        }
        return CGRect(x: place(size.width, around: viewport.midX, within: page.minX, page.maxX),
                      y: place(size.height, around: viewport.midY, within: page.minY, page.maxY),
                      width: size.width, height: size.height)
    }

    /// The first frame index for which `isPast` holds (frames are sorted top to bottom), or `frames.count`.
    private func firstIndex(where isPast: (CGRect) -> Bool) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if isPast(frames[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
