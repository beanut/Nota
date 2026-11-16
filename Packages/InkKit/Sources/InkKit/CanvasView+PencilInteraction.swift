import UIKit

// MARK: - Apple Pencil interactions

extension CanvasView: UIPencilInteractionDelegate {
    /// Double-tap (Pencil 2 and Pro). Does what the Pencil settings say, by default what Settings ›
    /// Apple Pencil says; a palette shows at the hover position.
    func pencilInteraction(_: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard let controller else { return }
        let action = controller.pencilSettings.doubleTap
            .resolved(system: UIPencilInteraction.preferredTapAction, fallback: .eraser)
        controller.perform(action, at: tap.hoverPose?.location ?? hoverLocation ?? center(of: bounds))
    }

    /// Squeeze (Pencil Pro): by default the quick palette, at the hover position.
    func pencilInteraction(_: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, let controller else { return }
        let action = controller.pencilSettings.squeeze
            .resolved(system: UIPencilInteraction.preferredSqueezeAction, fallback: .palette)
        controller.perform(action, at: squeeze.hoverPose?.location ?? hoverLocation ?? center(of: bounds))
    }

    private func center(of r: CGRect) -> CGPoint {
        CGPoint(x: r.midX, y: r.midY)
    }
}
