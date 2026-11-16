import UIKit

// MARK: - Gesture delegate

extension CanvasView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UIHoverGestureRecognizer {
            return true
        }
        if activeTouch != nil || zoomTouch != nil || isOnRuler(g) {
            return false
        } // palm rejection: no panning while the Pencil is down; a gesture on the ruler is the ruler's
        if g is TapeTapGestureRecognizer {
            return tapeTapShouldBegin(g)
        }
        if g === pan || g === pinch, let panel = zoomPanel, panel.frame.contains(g.location(in: self)) {
            return false // the writing panel stays put
        }
        if g === pinch {
            return g.numberOfTouches == 2
        }
        if g === lassoTap {
            return controller?.tool == .lasso && !fingerDraws
        }
        if g === textTap {
            return !fingerDraws && (controller?.tool == .text || textEditor != nil)
        }
        return true
    }

    /// Palm rejection: a resting hand never pans, zooms, swipes or taps.
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !isPalm(touch) && !isInTextEditor(touch) && !isInImageCrop(touch)
    }

    /// Whether the touch landed in the text box being edited.
    func isInTextEditor(_ touch: UITouch) -> Bool {
        guard let textView = textEditor?.textView, let view = touch.view else { return false }
        return view.isDescendant(of: textView)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g is MultiFingerTapRecognizer, other is UISwipeGestureRecognizer {
            return false
        }
        if g is UISwipeGestureRecognizer, other is MultiFingerTapRecognizer {
            return false
        }
        return true
    }

    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRequireFailureOf _: UIGestureRecognizer) -> Bool {
        false
    }
}
