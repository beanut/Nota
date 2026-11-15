import UIKit

// MARK: - Laser pointer

/// The laser pointer: a tool that draws nothing on the page. Its trail (`LaserTrail`) is drawn by its own
/// `LaserView` over the tape layer, never through the live or committed ink, and handed to the presentation
/// (`InkPresentation`) so an external display shows it too.
extension CanvasView {
    /// The view the laser is drawn in, made the first time the laser is used on this page.
    var laserView: LaserView {
        if let view = subviews.lazy.compactMap({ $0 as? LaserView }).first {
            return view
        }
        let view = LaserView(frame: bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.pageTransform = { [weak self] in self?.viewTransform ?? ViewTransform() }
        insertSubview(view, aboveSubview: tapeLayer)
        return view
    }

    func beginLaser(at p: CGPoint) {
        let view = laserView
        view.color = (controller?.theme ?? .standard).laser.uiColor
        let mode = controller?.laserMode ?? .trail
        var trail = view.trail
        if trail.mode != mode {
            trail = LaserTrail(mode: mode)
        }
        trail.begin(at: p, time: CACurrentMediaTime())
        showLaser(trail)
    }

    func moveLaser(to p: CGPoint) {
        var trail = laserView.trail
        trail.move(to: p, time: CACurrentMediaTime())
        showLaser(trail)
    }

    func endLaser() {
        var trail = laserView.trail
        trail.end(time: CACurrentMediaTime())
        showLaser(trail)
    }

    private func showLaser(_ trail: LaserTrail) {
        laserView.trail = trail
        controller?.presentation.laserDidChange(trail, on: document)
    }
}
