import UIKit

// MARK: - Embedded in continuous scrolling

/// A canvas embedded in `ContinuousCanvasView` (`isEmbedded`) shows one page among several: the host
/// places it, scrolls and zooms it, and makes it the page being worked on.
extension CanvasView {
    /// Whether the editor's tools and undo buttons describe this view: always, unless it's one of several
    /// pages in continuous scrolling and another one is the page being worked on.
    var isActiveCanvas: Bool {
        !isEmbedded || controller?.canvas === self
    }

    /// The zoom shown in the More menu; continuous scrolling reports its own.
    func reportZoom() {
        if !isEmbedded {
            controller?.zoomDidChange(viewTransform.scale)
        }
    }

    /// Moves an embedded page to `transform` as the host scrolls or zooms. `settled` once the movement
    /// has stopped, so the ink is drawn sharp at the new scale.
    func place(_ transform: ViewTransform, settled: Bool) {
        guard isEmbedded else { return }
        placementMoving = !settled
        if transform != placement {
            placement = transform
            viewTransform = transform
            updatePageChrome()
            liveView.follow(viewTransform)
            updateLassoOverlay()
        }
        if settled {
            liveView.settle(at: viewTransform)
        }
        // Cached tiles are laid out at once; only missing ones are filled, and none mid-pinch.
        coordinator.requestRender()
    }

    /// True while a stroke, erase or lasso is under way on the page, so the host doesn't scroll.
    var isInking: Bool {
        activeTouch != nil || zoomTouch != nil
    }

    /// Embedded, only the page itself takes touches; the gaps between pages belong to the scroll view.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEmbedded else { return super.point(inside: point, with: event) }
        return pageFrameInView.contains(point)
    }
}
