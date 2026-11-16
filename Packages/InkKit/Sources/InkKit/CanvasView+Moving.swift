import UIKit

// MARK: - Following the page while it moves

/// While a pan or pinch moves the page, what's already drawn (the committed ink, the template, the
/// page's objects) is scaled to follow it rather than drawn again every frame, and drawn again sharp once
/// the page stops, the way Notability and Xournal++ show a page while it zooms.
extension CanvasView {
    /// A pan or pinch is moving the page (or the host is scrolling or zooming it), so what's drawn is
    /// scaled to follow it and drawn again sharp once it stops.
    var isMovingView: Bool {
        isEmbedded ? placementMoving : activeGestureCount > 0 || settleLink != nil
    }

    /// The part of the view on screen: all of it, unless the host shows only part of an embedded page.
    var visibleInView: CGRect {
        placementVisible.map { $0.intersection(bounds) } ?? bounds
    }

    /// The view moved mid-gesture. The committed ink is drawn again only when the bitmap that's shown,
    /// or the one being drawn, no longer serves: it would be magnified too far, or it doesn't cover the
    /// page in view. Until then the layer scales it, so a fast pinch costs a few renders instead of one
    /// per frame. A pan (the scale unchanged) renders straight away, ahead of the edge coming into view.
    func requestRenderWhileMoving() {
        // One is already queued, to start at whatever the transform is by then; or there's nothing new.
        guard !fullRenderRequested, bitmapTransform != viewTransform else { return }
        if bitmapTransform.scale != viewTransform.scale,
           viewTransform.canReuse(drawnAt: bitmapTransform, over: bounds, visible: visibleInView,
                                  page: document.pageBounds) {
            return
        }
        requestFullRender()
    }
}
