import UIKit

// MARK: - Lasso overlay

/// Draws the lasso's path and the selection's outline over the canvas (`CanvasView.drawLassoOverlay(in:)`).
final class LassoOverlayView: UIView {
    weak var canvas: CanvasView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_: CGRect) {
        guard let canvas, let ctx = UIGraphicsGetCurrentContext() else { return }
        canvas.drawLassoOverlay(in: ctx)
    }
}
