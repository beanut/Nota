import UIKit

// MARK: - Ruler

/// Strokes along the ruler (`Ruler`, shown by `RulerView`). When a pen, pencil or highlighter stroke starts on
/// the ruler or near one of its edges, the edge is carried into page space once (`RulerGuide.mapped`), and
/// from then on every sample, predicted ones included, is projected onto it in `makePoint`: a dot product and
/// a multiply-add per point, so the live-ink path costs the same with the ruler as without. While the stroke
/// is drawn, its length (page centimetres) or the angle it sweeps round the protractor shows by the Pencil.
extension CanvasView {
    /// Shows or hides the ruler over this page, to match the controller. An embedded page (continuous
    /// scrolling) has no ruler of its own: the continuous view shows one over all of its pages.
    func updateRuler() {
        guard !isEmbedded, let controller else { return }
        RulerView.sync(in: self, controller: controller) { [weak self] _ in self }
    }

    /// Whether `g` started on the ruler: then it's the ruler's to move or turn, and the page doesn't pan,
    /// zoom or take the tap.
    func isOnRuler(_ g: UIGestureRecognizer) -> Bool {
        guard g.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)),
              let rulerView = controller?.rulerView, rulerView.window === window, !rulerView.isHidden else { return false }
        return rulerView.point(inside: g.location(in: rulerView), with: nil)
    }

    /// The live stroke just began at `start` (canvas space): if it's on or by the ruler's edge, it's drawn along it.
    func beginRulerSnap(at start: CGPoint) {
        rulerSnap = nil
        guard let controller, controller.rulerVisible, let rulerView = controller.rulerView,
              rulerView.window === window, !inputInZoomPanel, let live, !live.stroke.brush.erases else { return }
        let input = inputTransform
        let onRuler = rulerView.convert(input.toView(start), from: self)
        guard let guide = rulerView.ruler.guide(at: onRuler) else { return }
        rulerSnap = RulerMeasurement(guide: guide.mapped { input.toCanvas(convert($0, from: rulerView)) })
    }

    /// Measures the stroke along the ruler up to its latest point and shows the measurement by the Pencil.
    func updateRulerReadout(_ live: LiveStroke) {
        guard var snap = rulerSnap, let last = live.stroke.points.last?.location,
              let rulerView = controller?.rulerView else { return }
        snap.advance(to: last)
        rulerSnap = snap
        rulerView.showReadout(snap.readout, near: rulerView.convert(inputTransform.toView(last), from: self))
    }

    func endRulerSnap() {
        guard rulerSnap != nil else { return }
        rulerSnap = nil
        controller?.rulerView?.hideReadout()
    }
}
