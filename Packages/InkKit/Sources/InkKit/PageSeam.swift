import CoreGraphics
import Foundation

/// The rules for writing across a page boundary in continuous scrolling (`ContinuousCanvasView`).
///
/// A stroke that runs from one page onto the next is kept as one stroke per page, each in its own page's
/// coordinates. Each page takes part while the Pencil is within its `reach` above or below it, so the
/// pages' pieces overlap across the gap: the piece on the page above runs on past its bottom edge, and the
/// piece on the page below starts above its top edge. Every page clips its ink to the page, so what shows
/// of each piece is the same ink, from the same samples, up to the edge. The reach is longer than the
/// brush's tapers and its nib, so the ends of each piece (where a piece starts thin, or the end taper
/// narrows it) fall off the page, and the join doesn't show.
enum PageSeam {
    /// Added to every reach, so a piece's round end cap and the stabiliser settling in are off the page too.
    static let extraReach: CGFloat = 12
    /// The longest reach, however long the brush's taper: pieces overlap by at most this much.
    static let maxReach: CGFloat = 160

    /// The widest the brush's ink reaches from the centre line (canvas points), tilt shading included.
    static func inkRadius(of brush: BrushDescriptor) -> CGFloat {
        let tilt = brush.tilt.enabled ? 1 + max(brush.tilt.length, brush.tilt.breadth) : 1
        return brush.size.upperBound / 2 * tilt
    }

    /// How far above and below its page (canvas points) a page takes part in a stroke drawn with `brush`.
    static func reach(for brush: BrushDescriptor) -> CGFloat {
        let taper = brush.taper.isActive ? max(brush.taper.startLength, brush.taper.endLength) : 0
        return min(taper + inkRadius(of: brush) * 2 + extraReach, maxReach)
    }

    /// The reach for a stroke or standard erase with an eraser `radius` canvas points across.
    static func reach(eraserRadius radius: CGFloat) -> CGFloat {
        min(max(radius, 0) + extraReach, maxReach)
    }

    /// Whether `point` (canvas space) is within `reach` above or below a page `pageHeight` tall. Sideways
    /// doesn't matter: pages are stacked one above the other, and a stroke off the side stays on its page.
    static func reaches(_ point: CGPoint, pageHeight: CGFloat, reach: CGFloat) -> Bool {
        point.y >= -reach && point.y <= pageHeight + reach
    }

    /// Whether ink through `points`, `inkRadius` wide either side, shows anywhere on the page. A piece
    /// that only ran through the reach above or below its page leaves nothing on it and isn't kept.
    static func inkReachesPage(_ points: [CGPoint], pageBounds: CGRect, inkRadius: CGFloat) -> Bool {
        let area = pageBounds.insetBy(dx: -inkRadius, dy: -inkRadius)
        return points.contains { area.contains($0) }
    }
}
