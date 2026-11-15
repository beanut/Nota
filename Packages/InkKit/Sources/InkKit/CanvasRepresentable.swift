import SwiftUI
import UIKit

// MARK: - SwiftUI bridge

struct CanvasRepresentable: UIViewRepresentable {
    let controller: CanvasController
    let telemetry: PencilTelemetry
    let document: CanvasDocument

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero, document: document)
        view.controller = controller
        view.telemetry = telemetry
        controller.theme = context.environment.inkTheme
        view.apply(context.environment.inkTheme)
        controller.canvas = view
        // A new page: the tool palette's undo and selection state must describe this document.
        controller.documentDidChange(canUndo: document.canUndo, canRedo: document.canRedo)
        controller.selectionDidChange(false)
        if controller.zoomWindowVisible {
            view.zoomWindowVisibilityDidChange()
        }
        view.updateRuler()
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        controller.theme = context.environment.inkTheme
        view.apply(context.environment.inkTheme)
    }
}
