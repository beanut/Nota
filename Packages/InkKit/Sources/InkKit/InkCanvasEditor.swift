import SwiftUI

/// Full drawing surface: the raw-Pencil canvas showing one page on a desk, the Pen Case centered in the
/// navigation bar (the note's title lives in its More menu), a page bar for moving between, adding and
/// resizing pages, the debug HUD and the Pencil Pro quick palette.
///
/// Pass the same `InkNotebook` again to reopen it with every page's strokes and undo history intact.
///
/// ```swift
/// InkCanvasEditor(notebook: note.notebook, title: $note.title)
/// ```
///
/// The More menu's Zoom Window writes small, neat handwriting in a magnified panel at the bottom of the
/// screen. It follows each page's template ruling (`WritingLines.lines(for:on:)`); pass `writingLines` to
/// override that per page, where returning nil falls back to the template's.
public struct InkCanvasEditor: View {
    @ObservedObject private var notebook: InkNotebook
    private let showsDebugHUD: Bool
    private let showsPageControls: Bool
    private let title: Binding<String>?
    private let writingLines: ((CanvasDocument) -> WritingLines?)?

    @StateObject private var controller = CanvasController()
    @StateObject private var telemetry = PencilTelemetry()
    /// The side the next page slides in from when the canvas is swiped.
    @State private var pageTransitionEdge: Edge = .trailing
    /// True while a swiped page is sliding in. Further swipes wait: starting a second slide mid-way can
    /// leave the page stuck part-way across the screen.
    @State private var isTurningPage = false
    @Environment(\.inkTheme) private var theme

    /// A multi-page editor.
    public init(notebook: InkNotebook, title: Binding<String>? = nil, showsDebugHUD: Bool = false,
                writingLines: ((CanvasDocument) -> WritingLines?)? = nil) {
        self.notebook = notebook
        self.title = title
        self.showsDebugHUD = showsDebugHUD
        self.writingLines = writingLines
        showsPageControls = true
    }

    /// A single-page editor: the page can be resized but no pages can be added.
    public init(document: CanvasDocument, title: Binding<String>? = nil, showsDebugHUD: Bool = false,
                writingLines: ((CanvasDocument) -> WritingLines?)? = nil) {
        self.title = title
        notebook = InkNotebook(pages: [document], defaultPageSize: document.pageSize)
        self.showsDebugHUD = showsDebugHUD
        self.writingLines = writingLines
        showsPageControls = false
    }

    public var body: some View {
        ZStack {
            // A fresh canvas view per page: each CanvasView is bound to one document.
            CanvasRepresentable(controller: controller, telemetry: telemetry, document: notebook.currentPage)
                .id(notebook.currentPage.id)
                .transition(.push(from: pageTransitionEdge))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PageBar(notebook: notebook, allowsMultiplePages: showsPageControls)
                    .padding(.bottom, InkSpacing.s)
            }

            if controller.hudVisible {
                PencilHUD(telemetry: telemetry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
            }
        }
        .overlay {
            // The canvas view's coordinate space, where it lays out the zoom panel.
            if let frame = controller.zoomControlsFrame {
                ZoomWindowControls(controller: controller)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .ignoresSafeArea()
            }
        }
        .overlay {
            // Same full-screen coordinate space as the canvas view, so hover locations line up.
            if let location = controller.quickPaletteLocation {
                QuickPaletteView(controller: controller, location: location)
                    .ignoresSafeArea()
            }
        }
        .overlay {
            // Same coordinate space as the canvas view, so the eyedropper samples where it's touched.
            if controller.eyedropper != nil {
                EyedropperOverlay(controller: controller)
                    .ignoresSafeArea()
            }
        }
        .overlay {
            if controller.eyedropper != nil {
                EyedropperBanner(controller: controller)
            }
        }
        .background(theme.color(\.desk))
        .toolbar { penCaseItem }
        .sheet(item: $controller.brushEditorTool) { tool in
            BrushEditorView(controller: controller, tool: tool)
                .inkTheme(theme)
        }
        .onAppear {
            controller.hudVisible = showsDebugHUD
            controller.writingLines = writingLines
            controller.onSwipeToPage = { [notebook] swipe in turnPage(swipe, in: notebook) }
            controller.canSwipeToPage = { [notebook] swipe in canTurnPage(swipe, in: notebook) }
        }
    }

    /// The Pen Case centered on the navigation bar's row. Drawn flat, without the bar's shared glass background.
    @ToolbarContentBuilder
    private var penCaseItem: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: .principal) { PenCase(controller: controller, title: title) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { PenCase(controller: controller, title: title) }
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
