import SwiftUI

/// Full drawing surface: the raw-Pencil canvas, its floating tool palette, the debug HUD and the
/// Pencil Pro quick palette.
///
/// Pass the same `CanvasDocument` again to reopen a page with its strokes and undo history intact.
///
/// ```swift
/// InkCanvasEditor(document: page.document)
///     .navigationTitle(page.title)
/// ```
public struct InkCanvasEditor: View {
    private let document: CanvasDocument
    private let showsDebugHUD: Bool

    @StateObject private var controller = CanvasController()
    @StateObject private var telemetry = PencilTelemetry()

    public init(document: CanvasDocument, showsDebugHUD: Bool = false) {
        self.document = document
        self.showsDebugHUD = showsDebugHUD
    }

    public var body: some View {
        ZStack {
            CanvasRepresentable(controller: controller, telemetry: telemetry, document: document)
                .ignoresSafeArea()

            VStack {
                ToolbarView(controller: controller)
                Spacer()
            }
            .padding(.top, 8)

            if controller.hudVisible {
                PencilHUD(telemetry: telemetry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
            }
        }
        .overlay {
            // Same full-screen coordinate space as the canvas view, so hover locations line up.
            if let location = controller.quickPaletteLocation {
                QuickPaletteView(controller: controller, location: location)
                    .ignoresSafeArea()
            }
        }
        .onAppear { controller.hudVisible = showsDebugHUD }
    }
}

#Preview {
    InkCanvasEditor(document: CanvasDocument(), showsDebugHUD: true)
}
