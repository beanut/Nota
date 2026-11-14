import Combine
import SwiftUI
import UIKit

/// Continuous vertical scrolling: every page of a notebook in one column (`ContinuousPageLayout`).
///
/// A `UIScrollView` does the scrolling and zooming with the system's physics; it scrolls an empty stand-in
/// for the column. Only the pages in view are real: each gets an embedded `CanvasView` the size of the
/// viewport, placed (`CanvasView.place(_:settled:)`) so its page lands where the layout puts it, and
/// transparent outside the page. A page scrolled out of view loses its canvas and its bitmap, so memory
/// is bounded by what's on screen (at most `maxLiveCanvases` pages), not by the length of the note.
///
/// The page nearest the middle of the view is the notebook's current page; writing on another page in
/// view makes that one current. The tools, undo and selection act on the current page.
final class ContinuousCanvasView: UIView {
    let notebook: InkNotebook
    private(set) weak var controller: CanvasController?
    private weak var telemetry: PencilTelemetry?
    private var theme = InkTheme.standard

    private let scrollView = PageScrollView()
    /// Stands in for the column, so the scroll view has something to zoom. Never drawn.
    private let zoomView = UIView()
    /// The viewport, kept over the visible part of the content; holds the pages' canvases.
    private let pageContainer = UIView()
    /// Plain paper for pages in view that don't get a canvas (more than `maxLiveCanvases` tiny pages).
    private var paperLayers: [CALayer] = []

    private(set) var layout = ContinuousPageLayout(pageSizes: [], width: 0)
    private var laidOutWidth: CGFloat = 0
    private var laidOutInsets = ContinuousPageLayout.defaultInsets
    private var needsRelayout = true
    private var hasScrolledToInitialPage = false
    /// The page this view last made current (or saw made current), so a page chosen elsewhere (the page
    /// bar, the sidebar) can be told apart and scrolled to.
    private var trackedPageID: CanvasDocument.ID?
    private var canvases: [CanvasDocument.ID: CanvasView] = [:]
    private var notebookObservation: AnyCancellable?

    /// The most pages that have a live canvas at once. Pages fitted to the width rarely show more than
    /// three; this only matters for very short pages.
    static let maxLiveCanvases = 6

    init(notebook: InkNotebook, controller: CanvasController, telemetry: PencilTelemetry) {
        self.notebook = notebook
        self.controller = controller
        self.telemetry = telemetry
        super.init(frame: .zero)
        backgroundColor = theme.desk

        scrollView.host = self
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = ViewTransform.maxZoomFactor
        scrollView.delaysContentTouches = false
        scrollView.backgroundColor = .clear
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addSubview(scrollView)

        zoomView.isUserInteractionEnabled = false
        zoomView.isHidden = true
        scrollView.addSubview(zoomView)
        scrollView.addSubview(pageContainer)
        // The pinch recognizer exists once zooming is set up.
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        notebookObservation = notebook.objectWillChange.sink { [weak self] _ in
            // Sent before the change; lay out again once it's made.
            self?.needsRelayout = true
            self?.setNeedsLayout()
        }
        pencilSettingsDidChange()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ theme: InkTheme) {
        self.theme = theme
        backgroundColor = theme.desk
        for canvas in canvases.values {
            canvas.apply(theme)
        }
        let paper = theme.paper.resolvedColor(with: InkTheme.onPaper).cgColor
        for layer in paperLayers {
            layer.backgroundColor = paper
        }
    }

    /// Room for the navigation bar above the first page and the page bar below the last, plus the safe area.
    private var layoutInsets: ContinuousPageLayout.Insets {
        let base = ContinuousPageLayout.defaultInsets, s = safeAreaInsets
        return ContinuousPageLayout.Insets(top: base.top + s.top, side: base.side + max(s.left, s.right),
                                           bottom: base.bottom + s.bottom, gap: base.gap)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.frame != bounds {
            scrollView.frame = bounds
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let insets = layoutInsets
        if needsRelayout || bounds.width != laidOutWidth || insets != laidOutInsets {
            relayout(insets: insets)
        }
        let viewport = CGRect(origin: scrollView.contentOffset, size: bounds.size)
        if pageContainer.frame != viewport {
            pageContainer.frame = viewport
            for canvas in canvases.values where canvas.frame != pageContainer.bounds {
                canvas.frame = pageContainer.bounds
            }
        }
        updateVisiblePages(settled: !isMoving)
    }

    // MARK: Layout

    private func relayout(insets: ContinuousPageLayout.Insets) {
        needsRelayout = false
        let old = layout
        let z = scrollView.zoomScale
        // Keep the page that was being read where it was on screen.
        let anchorTop = trackedPageID.flatMap { oldIndex(of: $0, in: old) }
            .map { old.frames[$0].minY * z - scrollView.contentOffset.y }

        layout = ContinuousPageLayout(pageSizes: notebook.pages.map(\.pageSize.size), width: bounds.width,
                                      insets: insets)
        laidOutWidth = bounds.width
        laidOutInsets = insets
        let size = CGSize(width: layout.contentSize.width * z, height: layout.contentSize.height * z)
        zoomView.bounds = CGRect(origin: .zero, size: layout.contentSize)
        zoomView.center = CGPoint(x: size.width / 2, y: size.height / 2)
        if scrollView.contentSize != size {
            scrollView.contentSize = size
        }
        let oldIDs = pageFrameIDs
        pageFrameIDs = notebook.pages.map(\.id)
        // Pages of one size can be reordered without the frames changing; the page being read still moved.
        let moved = layout != old || pageFrameIDs != oldIDs

        let current = notebook.currentPage
        if !hasScrolledToInitialPage {
            hasScrolledToInitialPage = true
            trackedPageID = current.id
            scroll(toPage: notebook.currentPageIndex, animated: false)
        } else if current.id != trackedPageID {
            // Chosen in the page bar or the sidebar, added, or the page shown was deleted.
            trackedPageID = current.id
            scroll(toPage: notebook.currentPageIndex, animated: true)
        } else if moved, let anchorTop, let i = notebook.index(of: current.id) {
            setContentOffsetY(layout.frames[i].minY * z - anchorTop)
        }
    }

    /// The page ids in the order `layout.frames` has them.
    private var pageFrameIDs: [CanvasDocument.ID] = []

    private func oldIndex(of id: CanvasDocument.ID, in old: ContinuousPageLayout) -> Int? {
        guard let i = pageFrameIDs.firstIndex(of: id), old.frames.indices.contains(i) else { return nil }
        return i
    }

    private func setContentOffsetY(_ y: CGFloat) {
        let maxY = max(scrollView.contentSize.height - bounds.height, 0)
        let offset = CGPoint(x: scrollView.contentOffset.x, y: min(max(y, 0), maxY))
        if offset != scrollView.contentOffset {
            scrollView.contentOffset = offset
        }
    }

    /// Scrolls so page `index` shows from its top, just under the navigation bar.
    func scroll(toPage index: Int, animated: Bool) {
        let z = scrollView.zoomScale
        let y = layout.offset(showingPage: index, viewportHeight: bounds.height / z,
                              topInset: laidOutInsets.top / z) * z
        let offset = CGPoint(x: scrollView.contentOffset.x, y: y)
        guard offset != scrollView.contentOffset else { return }
        isAnimatingScroll = animated
        scrollView.setContentOffset(offset, animated: animated)
    }

    func resetZoom() {
        scrollView.setZoomScale(1, animated: true)
    }

    /// The visible part of the content, in layout points (zoom 1).
    private var viewportInLayout: CGRect {
        let z = scrollView.zoomScale, o = scrollView.contentOffset
        return CGRect(x: o.x / z, y: o.y / z, width: bounds.width / z, height: bounds.height / z)
    }

    /// True while `scroll(toPage:animated:)` slides to a page.
    private var isAnimatingScroll = false

    private var isMoving: Bool {
        isAnimatingScroll || scrollView.isDragging || scrollView.isDecelerating || scrollView.isZooming || scrollView.isZoomBouncing
    }

    /// Where page `index` is drawn in the viewport.
    private func transform(forPage index: Int) -> ViewTransform {
        let z = scrollView.zoomScale, o = scrollView.contentOffset, f = layout.frames[index]
        return ViewTransform(scale: layout.scale * z, offset: CGPoint(x: f.minX * z - o.x, y: f.minY * z - o.y))
    }

    // MARK: Pages in view

    /// Gives every page in view a canvas, places them, and lets go of the ones scrolled away.
    private func updateVisiblePages(settled: Bool) {
        let pages = notebook.pages
        guard layout.frames.count == pages.count else { return }
        let viewport = viewportInLayout
        let visible = layout.visiblePages(in: viewport)
        // Nearest the middle first, when there are more than the canvases allowed.
        let live = visible.sorted { abs(layout.frames[$0].midY - viewport.midY) < abs(layout.frames[$1].midY - viewport.midY) }
            .prefix(Self.maxLiveCanvases)
        let liveIDs = Set(live.map { pages[$0].id })

        for (id, canvas) in canvases where !liveIDs.contains(id) {
            if controller?.canvas === canvas {
                controller?.canvas = nil
            }
            canvas.removeFromSuperview()
            canvases[id] = nil
        }
        for i in live {
            let page = pages[i]
            let canvas = canvases[page.id] ?? makeCanvas(for: page)
            canvas.place(transform(forPage: i), settled: settled)
        }
        updatePaperLayers(for: visible.filter { !liveIDs.contains(pages[$0].id) })
        updateCurrentPage(in: viewport)
    }

    private func makeCanvas(for page: CanvasDocument) -> CanvasView {
        let canvas = CanvasView(frame: pageContainer.bounds, document: page, embedded: true)
        canvas.controller = controller
        canvas.telemetry = telemetry
        canvas.apply(theme)
        pageContainer.addSubview(canvas)
        canvases[page.id] = canvas
        return canvas
    }

    private func updatePaperLayers(for indices: [Int]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while paperLayers.count < indices.count {
            let layer = CALayer()
            layer.backgroundColor = theme.paper.resolvedColor(with: InkTheme.onPaper).cgColor
            pageContainer.layer.insertSublayer(layer, at: 0)
            paperLayers.append(layer)
        }
        for (layer, i) in zip(paperLayers, indices) {
            layer.isHidden = false
            layer.frame = transform(forPage: i).toView(notebook.pages[i].pageBounds)
        }
        for layer in paperLayers.dropFirst(indices.count) {
            layer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Makes the page in the middle of the view the current one, unless a page is taking ink.
    private func updateCurrentPage(in viewport: CGRect) {
        guard !isInking, let i = layout.currentPage(in: viewport), notebook.pages.indices.contains(i) else { return }
        let page = notebook.pages[i]
        if page.id != trackedPageID {
            trackedPageID = page.id
            notebook.goToPage(i)
        }
        if let canvas = canvases[page.id] {
            makeActive(canvas)
        }
    }

    // MARK: Working on a page

    var isInking: Bool {
        canvases.values.contains { $0.isInking }
    }

    /// Called as ink starts on `canvas`: it becomes the current page, and any scroll in progress stops so
    /// the page doesn't move under the Pencil.
    func activate(_ canvas: CanvasView) {
        if scrollView.isDragging || scrollView.isDecelerating || isAnimatingScroll {
            isAnimatingScroll = false
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        if let i = notebook.index(of: canvas.document.id) {
            trackedPageID = canvas.document.id
            notebook.goToPage(i)
        }
        makeActive(canvas)
    }

    private func makeActive(_ canvas: CanvasView) {
        guard let controller, controller.canvas !== canvas else { return }
        let previous = controller.canvas
        controller.canvas = canvas
        previous?.clearSelection()
        controller.documentDidChange(canUndo: canvas.document.canUndo, canRedo: canvas.document.canRedo)
        controller.selectionDidChange(false)
    }

    /// Writing near the bottom of the last page adds the next one.
    func inkDidCommit(on document: CanvasDocument, bounds: CGRect) {
        notebook.addPageIfWritingReachedEnd(of: document, inkBounds: bounds)
    }

    func pencilSettingsDidChange() {
        let fingerDraws = (controller?.pencilSettings.fingerDrawing ?? .system)
            .fingerDraws(pencilOnlySystemSetting: UIPencilInteraction.prefersPencilOnlyDrawing)
        scrollView.panGestureRecognizer.minimumNumberOfTouches = fingerDraws ? 2 : 1 // one finger draws
        for canvas in canvases.values {
            canvas.pencilSettingsDidChange()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            pencilSettingsDidChange() // Only Draw with Apple Pencil may have changed while away
        }
    }

    /// The colour shown at `point` (view coordinates): whichever page is there, or the desk.
    func sampledColor(at point: CGPoint) -> PenColor? {
        guard bounds.contains(point) else { return nil }
        return Eyedropper.sample(layer, at: point, scale: window?.screen.scale ?? traitCollection.displayScale)
    }
}

// MARK: - Scrolling

extension ContinuousCanvasView: UIScrollViewDelegate {
    func viewForZooming(in _: UIScrollView) -> UIView? {
        zoomView
    }

    func scrollViewDidScroll(_: UIScrollView) {
        setNeedsLayout()
        layoutIfNeeded()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        controller?.zoomDidChange(scrollView.zoomScale)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        isAnimatingScroll = false // a drag interrupts a slide to a page
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settle()
        }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        settle()
    }

    func scrollViewDidEndZooming(_: UIScrollView, with _: UIView?, atScale _: CGFloat) {
        settle()
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        isAnimatingScroll = false
        settle()
    }

    /// Movement stopped: draw the pages in view sharp where they are.
    private func settle() {
        guard !isMoving else { return }
        updateVisiblePages(settled: true)
    }
}

/// The scroll view behind continuous scrolling. It doesn't start scrolling or zooming while a page is
/// taking ink, so a hand resting on the screen as it writes doesn't move the page.
final class PageScrollView: UIScrollView {
    weak var host: ContinuousCanvasView?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer || g === pinchGestureRecognizer, host?.isInking == true {
            return false
        }
        return super.gestureRecognizerShouldBegin(g)
    }
}

// MARK: - SwiftUI bridge

struct ContinuousCanvasRepresentable: UIViewRepresentable {
    let controller: CanvasController
    let telemetry: PencilTelemetry
    let notebook: InkNotebook

    func makeUIView(context: Context) -> ContinuousCanvasView {
        let view = ContinuousCanvasView(notebook: notebook, controller: controller, telemetry: telemetry)
        controller.theme = context.environment.inkTheme
        view.apply(context.environment.inkTheme)
        controller.continuousHost = view
        controller.zoomDidChange(1)
        controller.selectionDidChange(false)
        return view
    }

    func updateUIView(_ view: ContinuousCanvasView, context: Context) {
        controller.theme = context.environment.inkTheme
        view.apply(context.environment.inkTheme)
    }

    static func dismantleUIView(_ view: ContinuousCanvasView, coordinator _: ()) {
        if let controller = view.controller, controller.continuousHost === view {
            controller.continuousHost = nil
        }
    }
}
