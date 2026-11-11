import SwiftUI

/// Full drawing surface: the raw-Pencil canvas showing one page on a desk, its floating tool palette,
/// a page bar for moving between, adding and resizing pages, the debug HUD and the Pencil Pro quick palette.
///
/// Pass the same `InkNotebook` again to reopen it with every page's strokes and undo history intact.
///
/// ```swift
/// InkCanvasEditor(notebook: note.notebook)
///     .navigationTitle(note.title)
/// ```
public struct InkCanvasEditor: View {
    @ObservedObject private var notebook: InkNotebook
    private let showsDebugHUD: Bool
    private let showsPageControls: Bool

    @StateObject private var controller = CanvasController()
    @StateObject private var telemetry = PencilTelemetry()
    /// The side the next page slides in from when the canvas is swiped.
    @State private var pageTransitionEdge: Edge = .trailing
    /// True while a swiped page is sliding in. Further swipes wait: starting a second slide mid-way can
    /// leave the page stuck part-way across the screen.
    @State private var isTurningPage = false

    /// A multi-page editor.
    public init(notebook: InkNotebook, showsDebugHUD: Bool = false) {
        self.notebook = notebook
        self.showsDebugHUD = showsDebugHUD
        self.showsPageControls = true
    }

    /// A single-page editor: the page can be resized but no pages can be added.
    public init(document: CanvasDocument, showsDebugHUD: Bool = false) {
        self.notebook = InkNotebook(pages: [document], defaultPageSize: document.pageSize)
        self.showsDebugHUD = showsDebugHUD
        self.showsPageControls = false
    }

    public var body: some View {
        ZStack {
            // A fresh canvas view per page: each CanvasView is bound to one document.
            CanvasRepresentable(controller: controller, telemetry: telemetry, document: notebook.currentPage)
                .id(notebook.currentPage.id)
                .transition(.push(from: pageTransitionEdge))
                .ignoresSafeArea()

            VStack {
                ToolbarView(controller: controller)
                Spacer()
                PageBar(notebook: notebook, allowsMultiplePages: showsPageControls)
            }
            .padding(.vertical, 8)

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
        .onAppear {
            controller.hudVisible = showsDebugHUD
            controller.onSwipeToPage = { [notebook] swipe in turnPage(swipe, in: notebook) }
            controller.canSwipeToPage = { [notebook] swipe in canTurnPage(swipe, in: notebook) }
        }
    }

    /// Swiping left shows the next page and swiping right the previous one, sliding the new page in
    /// from the side the finger came from. Swiping past the first or last page does nothing.
    private func canTurnPage(_ swipe: PageSwipe, in notebook: InkNotebook) -> Bool {
        !isTurningPage && (swipe == .next ? notebook.canGoToNextPage : notebook.canGoToPreviousPage)
    }

    private func turnPage(_ swipe: PageSwipe, in notebook: InkNotebook) {
        guard canTurnPage(swipe, in: notebook) else { return }
        let next = swipe == .next
        pageTransitionEdge = next ? .trailing : .leading
        isTurningPage = true
        withAnimation(.snappy(duration: 0.3), completionCriteria: .removed) {
            next ? notebook.goToNextPage() : notebook.goToPreviousPage()
        } completion: {
            isTurningPage = false
        }
    }
}

#Preview {
    InkCanvasEditor(notebook: InkNotebook(pageCount: 3), showsDebugHUD: true)
}
