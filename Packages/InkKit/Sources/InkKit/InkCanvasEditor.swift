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
/// The More menu's Scroll Direction shows pages one at a time with sideways swipes (horizontal) or all of
/// them in one column scrolled vertically (`PageLayoutMode`). The page bar's pages button opens the page
/// sidebar: thumbnails to jump between, reorder, duplicate, rotate and delete pages. Pass `pageDestinations`
/// and `sendPages` to also copy or move pages to other notes.
///
/// The More menu's Zoom Window writes small, neat handwriting in a magnified panel at the bottom of the
/// screen. It follows each page's template ruling (`WritingLines.lines(for:on:)`); pass `writingLines` to
/// override that per page, where returning nil falls back to the template's.
///
/// The lasso selects ink and objects (its Tool Options filter which). Its selection's menu cuts, copies,
/// pastes (onto any page of any note), duplicates, deletes, recolours, thickens and thins, brings to front or
/// sends to back, and takes a screenshot; a selection can also be dragged out to other apps as an image.
/// Pass `selectionActions` to add the app's own items to that menu.
///
/// The Pen Case's Insert menu puts pictures on the page from Photos, the camera, Files or the pasteboard
/// (pictures can also be dropped onto the page), and places stickers: selections saved with the selection
/// menu's Save as Sticker (`StickerStore.shared`). A selected picture's menu crops it (to a rectangle or
/// freehand, and back) and sets its opacity. Pictures' bytes live in `ImageAssets.shared`; a host that
/// stores notes registers where it keeps them there.
public struct InkCanvasEditor: View {
    @ObservedObject private var notebook: InkNotebook
    private let showsDebugHUD: Bool
    private let showsPageControls: Bool
    private let title: Binding<String>?
    private let writingLines: ((CanvasDocument) -> WritingLines?)?
    private let pageDestinations: [PageDestination]
    private let sendPages: PageSender?
    private let selectionActions: [SelectionAction]

    @StateObject private var controller = CanvasController()
    @StateObject private var telemetry = PencilTelemetry()
    /// The side the next page slides in from when the canvas is swiped.
    @State private var pageTransitionEdge: Edge = .trailing
    /// True while a swiped page is sliding in. Further swipes wait: starting a second slide mid-way can
    /// leave the page stuck part-way across the screen.
    @State private var isTurningPage = false
    @State private var showsSidebar = false
    @Environment(\.inkTheme) private var theme

    /// A multi-page editor.
    public init(notebook: InkNotebook, title: Binding<String>? = nil, showsDebugHUD: Bool = false,
                writingLines: ((CanvasDocument) -> WritingLines?)? = nil,
                pageDestinations: [PageDestination] = [], sendPages: PageSender? = nil,
                selectionActions: [SelectionAction] = []) {
        self.notebook = notebook
        self.title = title
        self.showsDebugHUD = showsDebugHUD
        self.writingLines = writingLines
        self.pageDestinations = pageDestinations
        self.sendPages = sendPages
        self.selectionActions = selectionActions
        showsPageControls = true
    }

    /// A single-page editor: the page can be resized but no pages can be added.
    public init(document: CanvasDocument, title: Binding<String>? = nil, showsDebugHUD: Bool = false,
                writingLines: ((CanvasDocument) -> WritingLines?)? = nil,
                selectionActions: [SelectionAction] = []) {
        self.title = title
        self.selectionActions = selectionActions
        notebook = InkNotebook(pages: [document], defaultPageSize: document.pageSize)
        self.showsDebugHUD = showsDebugHUD
        self.writingLines = writingLines
        pageDestinations = []
        sendPages = nil
        showsPageControls = false
    }

    public var body: some View {
        ZStack {
            if isContinuous {
                ContinuousCanvasRepresentable(controller: controller, telemetry: telemetry, notebook: notebook)
                    .ignoresSafeArea()
            } else {
                // A fresh canvas view per page: each CanvasView is bound to one document.
                CanvasRepresentable(controller: controller, telemetry: telemetry, document: notebook.currentPage)
                    .id(notebook.currentPage.id)
                    .transition(.push(from: pageTransitionEdge))
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PageBar(notebook: notebook, allowsMultiplePages: showsPageControls,
                        showsSidebar: showsPageControls ? $showsSidebar : nil)
                    .padding(.bottom, InkSpacing.s)
            }

            if showsSidebar, showsPageControls {
                PageSidebar(notebook: notebook, destinations: pageDestinations, sendPages: sendPages) {
                    withAnimation(.snappy) { showsSidebar = false }
                }
                .padding(.leading, InkSpacing.m)
                .padding(.top, InkSpacing.s)
                .padding(.bottom, InkSpacing.s + InkMetrics.barHeight + InkSpacing.s) // clear of the page bar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if let format = controller.textFormat {
                ScrollView(.horizontal, showsIndicators: false) {
                    TextFormatBar(controller: controller, state: format)
                        .padding(InkSpacing.s)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let crop = controller.imageCrop {
                ImageCropBar(controller: controller, state: crop)
                    .padding(InkSpacing.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
            controller.allowsContinuousLayout = showsPageControls
            controller.writingLines = writingLines
            controller.selectionActions = selectionActions
            controller.onSwipeToPage = { [notebook] swipe in turnPage(swipe, in: notebook) }
            controller.canSwipeToPage = { [notebook] swipe in canTurnPage(swipe, in: notebook) }
        }
    }

    /// Continuous vertical scrolling, for a notebook (a single-page editor always shows its one page).
    private var isContinuous: Bool {
        showsPageControls && controller.pageLayout == .continuous
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
