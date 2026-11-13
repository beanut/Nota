import UIKit

/// Canvas → view mapping: uniform scale then translation, no rotation.
/// Because there's no rotation, angles (azimuth) are the same in both spaces.
struct ViewTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGPoint = .zero

    var affine: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.x, ty: offset.y)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        r.isNull ? r : r.applying(affine)
    }

    func toCanvas(_ r: CGRect) -> CGRect {
        r.isNull ? r : r.applying(affine.inverted())
    }

    /// The transform that shows all of `page` (canvas space) as large as possible inside `bounds` minus
    /// `insets`, centred. Scale is clamped to `scaleRange`. Empty inputs give the identity.
    static func fitting(page: CGRect, in bounds: CGRect, insets: UIEdgeInsets = .zero,
                        scaleRange: ClosedRange<CGFloat> = 0.25 ... 8) -> ViewTransform {
        // Not `bounds.inset(by:)`: a rect inset past empty is standardized to a positive size.
        let available = CGRect(x: bounds.minX + insets.left, y: bounds.minY + insets.top,
                               width: bounds.width - insets.left - insets.right,
                               height: bounds.height - insets.top - insets.bottom)
        guard page.width > 0, page.height > 0, available.size.width > 0, available.size.height > 0 else {
            return ViewTransform()
        }
        let fit = min(available.width / page.width, available.height / page.height)
        let scale = min(max(fit, scaleRange.lowerBound), scaleRange.upperBound)
        return ViewTransform(scale: scale,
                             offset: CGPoint(x: available.midX - page.midX * scale,
                                             y: available.midY - page.midY * scale))
    }

    /// The most a page can be zoomed in, as a multiple of the scale that fits the whole page in view.
    static let maxZoomFactor: CGFloat = 6
    /// The scales a page can be zoomed to, given `fitScale`, the scale that shows the whole page.
    /// Zooming out stops at the whole page. Zooming in stops at `maxZoomFactor` × the fitted scale, or
    /// `maxZoomFactor` × actual size if that's larger, so a very large page can still be zoomed in to write on.
    static func zoomRange(fitScale: CGFloat) -> ClosedRange<CGFloat> {
        guard fitScale > 0, fitScale.isFinite else { return 1 ... maxZoomFactor }
        return fitScale ... max(fitScale, 1) * maxZoomFactor
    }

    /// How far (0–1) to move the page towards its centred, fitted position when a pinch zooms from `old`
    /// to `new`. Within 25% of `fitScale`, zooming out closes the gap in step with the scale, so the page
    /// arrives centred exactly as it reaches the zoom-out limit. Zooming in, or above that band, gives 0.
    static func recentringAmount(from old: CGFloat, to new: CGFloat, fitScale: CGFloat) -> CGFloat {
        guard fitScale > 0 else { return 0 }
        if new <= fitScale {
            return 1
        }
        let start = min(old, fitScale * 1.25)
        guard new < start else { return 0 }
        return (start - new) / (start - fitScale)
    }
}

/// A horizontal swipe that turns the page.
enum PageSwipe: Equatable {
    case next, previous

    /// The page turn a finished pan asks for, if any. `translation` is the pan's total movement and
    /// `velocity` its speed when the fingers lifted, both in view points. A swipe has to be mostly
    /// sideways and either travel a quarter of `viewWidth` or be a quick flick. Swiping left (the page
    /// moving left) shows the next page.
    static func detect(translation: CGPoint, velocity: CGPoint, viewWidth: CGFloat) -> PageSwipe? {
        let dx = translation.x, dy = translation.y
        guard viewWidth > 0, abs(dx) > abs(dy) * 1.5 else { return nil }
        let farEnough = abs(dx) > viewWidth * 0.25
        let flicked = abs(dx) > 40 && abs(velocity.x) > 600 && velocity.x.sign == dx.sign
        guard farEnough || flicked else { return nil }
        return dx < 0 ? .next : .previous
    }
}
