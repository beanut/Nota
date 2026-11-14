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
