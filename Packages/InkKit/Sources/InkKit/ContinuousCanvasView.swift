import Combine
import SwiftUI
import UIKit

/// Continuous vertical scrolling: every page of a notebook in one column (`ContinuousPageLayout`).
///
/// A `UIScrollView` does the scrolling and zooming with the system's physics; it scrolls an empty stand-in
/// for the column. Only the pages in or near the view are real: each gets an embedded `CanvasView`
/// covering its render window (`ContinuousPageLayout.renderWindow`: the whole page at zoom 1, the
/// viewport plus a margin when zoomed in), placed (`CanvasView.place(_:settled:)`) so its page lands where
/// the layout puts it, and transparent outside the page. The canvases sit in the scroll content, so
/// scrolling moves their rendered ink with the paper instead of rendering it again; a page only renders
/// when its window moves or the zoom changes. Pages just outside the view get their canvas early, so
/// their ink is ready before they scroll in. A page scrolled away loses its canvas and its bitmap, so
/// memory is bounded by what's on screen (at most `maxLiveCanvases` pages), not by the length of the note.
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
    /// Covers the whole content; holds the pages' canvases, each over its render window.
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
    /// How far above and below the view, as a fraction of its height, pages get a canvas before they're
    /// in view.
    static let prefetchFraction: CGFloat = 0.5
    /// Mid-pinch, how far above and below the view a page keeps the canvas it has. A pinch changes which
    /// pages are near the view every frame; making and dropping canvases for them (each a new bitmap and a
    /// full render) is what made pinching across a page break stutter. So mid-pinch a page only gets a
    /// canvas once it's in view, and only loses one once it's this far out.
    static let pinchKeepFraction: CGFloat = 1

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
        let content = CGRect(origin: .zero, size: scrollView.contentSize)
        if pageContainer.frame != content {
            pageContainer.frame = content
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

    /// Where page `index` is drawn in a view whose top-left is at `origin` in the content (at the current zoom).
    private func transform(forPage index: Int, from origin: CGPoint = .zero) -> ViewTransform {
        let z = scrollView.zoomScale, f = layout.frames[index]
        return ViewTransform(scale: layout.scale * z,
                             offset: CGPoint(x: f.minX * z - origin.x, y: f.minY * z - origin.y))
    }

    /// Page `index`'s frame in the content at the current zoom.
    private func contentFrame(ofPage index: Int) -> CGRect {
        let z = scrollView.zoomScale, f = layout.frames[index]
        return CGRect(x: f.minX * z, y: f.minY * z, width: f.width * z, height: f.height * z)
    }

    // MARK: Pages in view

    /// Gives every page in or near the view a canvas, places them, and lets go of the ones scrolled away.
    private func updateVisiblePages(settled: Bool) {
        let pages = notebook.pages
        guard layout.frames.count == pages.count else { return }
        let viewport = viewportInLayout
        let visible = layout.visiblePages(in: viewport)
        let pinching = scrollView.isZooming || scrollView.isZoomBouncing
        let nearby: [Int] = if pinching {
            layout.visiblePages(in: viewport.insetBy(dx: 0, dy: -viewport.height * Self.pinchKeepFraction))
                .filter { visible.contains($0) || canvases[pages[$0].id] != nil }
        } else {
            Array(layout.visiblePages(in: viewport.insetBy(dx: 0, dy: -viewport.height * Self.prefetchFraction)))
        }
        // Nearest the middle first, when there are more than the canvases allowed.
        let live = nearby.sorted { abs(layout.frames[$0].midY - viewport.midY) < abs(layout.frames[$1].midY - viewport.midY) }
            .prefix(Self.maxLiveCanvases)
        var liveIDs = Set(live.map { pages[$0].id })
        // A page taking ink, or the one a stroke across pages began on (its touch still arrives there),
        // keeps its canvas until the stroke ends.
        for (id, canvas) in canvases where canvas.isInking || canvas === crossing?.origin {
            liveIDs.insert(id)
        }

        for (id, canvas) in canvases where !liveIDs.contains(id) {
            if controller?.canvas === canvas {
                controller?.canvas = nil
            }
            canvas.removeFromSuperview()
            canvases[id] = nil
        }
        let contentViewport = CGRect(origin: scrollView.contentOffset, size: bounds.size)
        for i in live {
            let page = pages[i]
            let existing = canvases[page.id]
            // A page taking ink stays where it is, so the ink under the Pencil doesn't move.
            let window = existing.flatMap { $0.isInking ? $0.frame : nil }
                ?? ContinuousPageLayout.renderWindow(forPage: contentFrame(ofPage: i), viewport: contentViewport,
                                                     current: existing?.frame, keepingSize: pinching)
            let canvas = existing ?? makeCanvas(for: page, frame: window)
            if canvas.frame != window {
                canvas.frame = window
            }
            let onScreen = contentViewport.intersection(window).offsetBy(dx: -window.minX, dy: -window.minY)
            canvas.place(transform(forPage: i, from: window.origin), visible: onScreen, settled: settled)
            // A new or resized canvas makes its bitmap now, at the placement it was just given, so its
            // first render already shows the page.
            canvas.layoutIfNeeded()
        }
        updatePaperLayers(for: visible.filter { !liveIDs.contains(pages[$0].id) })
        // Pinching across a page break moves the middle of the view between the two pages over and
        // over; the current page (the page bar, undo, the tools) catches up once the pinch ends.
        if !pinching {
            updateCurrentPage(in: viewport)
        }
    }

    private func makeCanvas(for page: CanvasDocument, frame: CGRect) -> CanvasView {
        let canvas = CanvasView(frame: frame, document: page, embedded: true)
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
        crossing != nil || canvases.values.contains { $0.isInking }
    }

    // MARK: Writing across pages

    /// A stroke (ink or an eraser) that may carry on from the page it began on to the pages above and
    /// below (`PageSeam`). Its touch keeps arriving at the page it began on, which hands each event here;
    /// every page with a canvas takes part while the Pencil is within `reach` of it, with a piece of its
    /// own. The pieces share `group`, so undo takes them back together.
    private struct Crossing {
        let touch: UITouch
        weak var origin: CanvasView?
        let group: UUID
        let reach: CGFloat
        /// Ink, not an eraser: writing past the last page adds a page.
        let isInk: Bool
        var addedPage = false
    }

    private var crossing: Crossing?

    func isWritingAcrossPages(_ touch: UITouch) -> Bool {
        crossing?.touch === touch
    }

    /// `canvas` began a stroke with `touch` that can carry on onto other pages.
    func beginWritingAcrossPages(_ touch: UITouch, event: UIEvent?, on canvas: CanvasView) {
        crossing = Crossing(touch: touch, origin: canvas, group: UUID(), reach: canvas.acrossPagesReach,
                            isInk: canvas.live.map { !$0.stroke.brush.erases } ?? false)
        canvas.strokeGroup = crossing?.group
        writingAcrossPagesMoved(touch, event: event, from: canvas) // a page just above or below may be in reach already
    }

    /// The next event of the stroke, after the page it began on has handled it: the other pages taking
    /// part get it too, pages coming into reach join, and pages going out of reach end their piece.
    func writingAcrossPagesMoved(_ touch: UITouch, event: UIEvent?, from origin: CanvasView) {
        guard var crossing, crossing.touch === touch else { return }
        // Writing past the end of the last page adds the next page, so the stroke can carry on onto it.
        if crossing.isInk, !crossing.addedPage, let last = notebook.pages.last, let canvas = canvases[last.id],
           canvas.viewTransform.toCanvas(touch.preciseLocation(in: canvas)).y > last.pageSize.height {
            crossing.addedPage = true
            self.crossing = crossing
            notebook.addPageIfWritingReachedEnd(of: last, inkBounds: CGRect(x: 0, y: last.pageSize.height, width: 0, height: 0))
            layoutIfNeeded() // gives the new page its canvas now
        }
        var joined = false
        for canvas in canvases.values {
            let taking = canvas.activeTouch === touch
            if taking, canvas !== origin {
                canvas.continueStroke(touch, event: event)
            }
            let inReach = canvas.reaches(touch, within: crossing.reach)
            if taking, !inReach {
                canvas.leaveStroke(touch, event: event, final: false, commit: true)
            } else if !taking, inReach {
                canvas.joinStroke(touch, event: event, group: crossing.group)
                joined = joined || canvas.activeTouch === touch
            }
        }
        if joined {
            // A stroke on two pages isn't a shape held still on one.
            for canvas in canvases.values {
                canvas.stopHoldWatch()
            }
        }
    }

    /// The stroke ended (or was cancelled) on the page it began on; the other pages taking part end theirs.
    func endWritingAcrossPages(_ touch: UITouch, event: UIEvent?, commit: Bool, from origin: CanvasView) {
        guard crossing?.touch === touch else { return }
        crossing = nil
        for canvas in canvases.values where canvas !== origin && canvas.activeTouch === touch {
            canvas.leaveStroke(touch, event: event, final: true, commit: commit)
        }
        if commit {
            controller?.eraserStrokeDidEnd() // goes back to the previous tool, if that's on and this was an erase
        }
        setNeedsLayout() // let go of pages that only kept their canvas for the stroke
    }

    /// Refined force and tilt for a stroke's samples arrive at the page it began on; the pages that took
    /// part apply them to their own pieces.
    func forwardEstimates(_ touches: Set<UITouch>, from origin: CanvasView) {
        for canvas in canvases.values where canvas !== origin {
            canvas.applyEstimates(touches, recording: false)
        }
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

    /// Shows or hides the ruler over every page, to match the controller. A Pencil touch on the ruler writes
    /// on the page under it.
    func updateRuler() {
        guard let controller else { return }
        RulerView.sync(in: self, controller: controller) { [weak self] p in self?.canvas(at: p) }
    }

    /// The page's canvas at `point` (this view's space), if a page with a canvas is there.
    func canvas(at point: CGPoint) -> CanvasView? {
        canvases.values.first { canvas in
            canvas.pageFrameInView.contains(canvas.convert(point, from: self))
        }
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
        controller?.zoomDidChange(scrollView.zoomScale, settled: !scrollView.isZooming && !scrollView.isZoomBouncing)
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

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with _: UIView?, atScale _: CGFloat) {
        controller?.zoomDidChange(scrollView.zoomScale)
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
        view.updateRuler()
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
