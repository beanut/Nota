import NotaUI
import SwiftUI

/// Full drawing surface: the raw-Pencil canvas showing one page on a desk, the floating Pen Case (docked to
/// any edge; the choice is remembered),
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
    /// The edge the Pen Case is docked to, remembered across launches.
    @AppStorage("InkKit.toolbarDock") private var dock: ToolbarDock = .top

    /// A multi-page editor.
    public init(notebook: InkNotebook, showsDebugHUD: Bool = false) {
        self.notebook = notebook
        self.showsDebugHUD = showsDebugHUD
        showsPageControls = true
    }

    /// A single-page editor: the page can be resized but no pages can be added.
    public init(document: CanvasDocument, showsDebugHUD: Bool = false) {
        notebook = InkNotebook(pages: [document], defaultPageSize: document.pageSize)
        self.showsDebugHUD = showsDebugHUD
        showsPageControls = false
    }

    public var body: some View {
        ZStack {
            // A fresh canvas view per page: each CanvasView is bound to one document.
            CanvasRepresentable(controller: controller, telemetry: telemetry, document: notebook.currentPage)
                .id(notebook.currentPage.id)
                .transition(.push(from: pageTransitionEdge))
                .ignoresSafeArea()

            GeometryReader { proxy in
                ZStack(alignment: dock.alignment) {
                    Color.clear
                    PenCase(controller: controller, dock: dock, onDock: setDock) { drop in
                        setDock(ToolbarDock.nearest(to: drop, in: proxy.size))
                    }
                    .padding(penCaseInsets)
                }
                ZStack(alignment: .bottom) {
                    Color.clear
                    PageBar(notebook: notebook, allowsMultiplePages: showsPageControls)
                        .padding(.bottom, NotaSpacing.s)
                }
            }
            .coordinateSpace(name: PenCase.coordinateSpace)

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
        .background(NotaColor.bgDesk)
        .onChange(of: dock, initial: true) { _, dock in controller.pageMargins = Self.pageMargins(for: dock) }
        .onAppear {
            controller.hudVisible = showsDebugHUD
            controller.onSwipeToPage = { [notebook] swipe in turnPage(swipe, in: notebook) }
            controller.canSwipeToPage = { [notebook] swipe in canTurnPage(swipe, in: notebook) }
        }
    }

    private func setDock(_ newDock: ToolbarDock) {
        withAnimation(.snappy) { dock = newDock }
    }

    /// Keeps the Pen Case off the screen edge and, docked at the bottom, above the page bar.
    private var penCaseInsets: EdgeInsets {
        switch dock {
        case .top: EdgeInsets(top: NotaSpacing.s, leading: 0, bottom: 0, trailing: 0)
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: NotaSpacing.s * 2 + NotaSize.bar, trailing: 0)
        case .leading: EdgeInsets(top: 0, leading: NotaSpacing.m, bottom: 0, trailing: 0)
        case .trailing: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: NotaSpacing.m)
        }
    }

    /// Room around the fitted page for the Pen Case on `dock` and the page bar at the bottom.
    static func pageMargins(for dock: ToolbarDock) -> UIEdgeInsets {
        let bar: CGFloat = 76 // a 44 pt bar, its inset from the edge and a gap before the page
        let side: CGFloat = 24
        switch dock {
        case .top: return UIEdgeInsets(top: bar, left: side, bottom: bar, right: side)
        case .bottom: return UIEdgeInsets(top: side, left: side, bottom: bar + NotaSize.bar + NotaSpacing.s, right: side)
        case .leading: return UIEdgeInsets(top: side, left: bar, bottom: bar, right: side)
        case .trailing: return UIEdgeInsets(top: side, left: side, bottom: bar, right: bar)
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
