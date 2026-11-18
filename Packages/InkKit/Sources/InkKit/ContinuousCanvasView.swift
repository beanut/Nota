import Combine
import SwiftUI
import UIKit

/// Continuous vertical scrolling: every page of a notebook in one column (`ContinuousPageLayout`).
///
/// A `UIScrollView` does the scrolling and zooming with the system's physics; it scrolls an empty stand-in
/// for the column. Only the pages in or near the view are real: each is shown by an embedded `CanvasView`
/// covering its render window (`ContinuousPageLayout.renderWindow`: the whole page at zoom 1, the
/// viewport plus a margin when zoomed in), placed (`CanvasView.place(_:settled:)`) so its page lands where
/// the layout puts it, and transparent outside the page. The committed ink is page-space tiles in the
/// shared `TileCache`, so a canvas shows whatever of its page is cached at once and fills only what isn't;
/// the canvases sit in the scroll content, so scrolling moves them, ink and all, with the paper.
///
/// Canvases are pooled (NOT-107): a page leaving view leaves its tiles with its document and hands its
/// canvas, with its layers, gestures and interactions, to the next page entering view
/// (`CanvasView.leavePage()`, `show(_:)`), so scrolling makes no views. Pages get their canvas ahead of
/// the view (`ContinuousPageLayout.prefetchRect`), further ahead the faster it scrolls; one not on screen
/// yet fills its tiles behind the pages on screen (`CanvasView.isAhead`). Memory is bounded by the pages
/// near the view (at most `maxLiveCanvases`), not by the length of the note.
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
    /// The pages that have a canvas now (in or near the view).
    var liveCanvases: [CanvasView] {
        Array(canvases.values)
    }

    /// Canvases whose page left view, hidden, waiting for the next page to enter it.
    private(set) var spareCanvases: [CanvasView] = []
    /// How many canvases this view has made: once the pool is warm, scrolling makes none.
    private(set) var canvasesMade = 0

    /// How fast the column is scrolling, in layout points (zoom 1) per second, positive downwards; zero
    /// once it stops. Pages further ahead of a faster scroll get their canvas (`prefetchRect`).
    private(set) var scrollVelocity: CGFloat = 0
    private var lastScrollSample: (y: CGFloat, time: CFTimeInterval)?

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
        for canvas in canvases.values + spareCanvases {
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
        isAnimatingScroll || isScrollingForTesting || scrollView.isDragging || scrollView.isDecelerating
            || scrollView.isZooming || scrollView.isZoomBouncing
    }

    // MARK: Scrolling from tests

    /// True between `scrollForTesting(toY:)` and `endScrollingForTesting()`: the column moves as a drag or a
    /// fling would move it.
    private var isScrollingForTesting = false

    /// Scrolls the column so its top `y` content points (at the current zoom) is at the top of the view, as
    /// one frame of a drag or fling: pages are placed moving, at the scroll's speed.
    func scrollForTesting(toY y: CGFloat) {
        isScrollingForTesting = true
        setContentOffsetY(y)
    }

    /// The scroll `scrollForTesting(toY:)` drove stopped: the pages in view settle where they are.
    func endScrollingForTesting() {
        isScrollingForTesting = false
        settle()
    }

    /// How far the column is scrolled: the content offset's y, at the current zoom.
    var contentOffsetForTesting: CGFloat {
        scrollView.contentOffset.y
    }

    /// The pages in view (`layout` indices).
    var pagesInView: Range<Int> {
        layout.visiblePages(in: viewportInLayout)
    }

    /// The canvas showing `page`, if it has one.
    func canvas(showing page: CanvasDocument.ID) -> CanvasView? {
        canvases[page]
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
        let nearby = layout.visiblePages(in: ContinuousPageLayout.prefetchRect(around: viewport, velocity: scrollVelocity))
        // The pages in view first, then those ahead nearest first, when there are more than the canvases allowed.
        let live = nearby.sorted { a, b in
            let inA = visible.contains(a), inB = visible.contains(b)
            if inA != inB {
                return inA
            }
            return abs(layout.frames[a].midY - viewport.midY) < abs(layout.frames[b].midY - viewport.midY)
        }
        .prefix(Self.maxLiveCanvases)
        var liveIDs = Set(live.map { pages[$0].id })
        // A page taking ink, or the one a stroke across pages began on (its touch still arrives there),
        // keeps its canvas until the stroke ends.
        for (id, canvas) in canvases where canvas.isInking || canvas === crossing?.origin {
            liveIDs.insert(id)
        }

        for (id, canvas) in canvases where !liveIDs.contains(id) {
            release(canvas)
            canvases[id] = nil
        }
        let contentViewport = CGRect(origin: scrollView.contentOffset, size: bounds.size)
        let pinching = scrollView.isZooming || scrollView.isZoomBouncing
        for i in live {
            let page = pages[i]
            let existing = canvases[page.id]
            // A page taking ink stays where it is, so the ink under the Pencil doesn't move.
            let window = existing.flatMap { $0.isInking ? $0.frame : nil }
                ?? ContinuousPageLayout.renderWindow(forPage: contentFrame(ofPage: i), viewport: contentViewport,
                                                     current: existing?.frame, keepingSize: pinching)
            let canvas = existing ?? canvas(for: page, frame: window)
            if canvas.frame != window {
                canvas.frame = window
            }
            // The column at zoom 1 is what zooming back out returns to: its tiles are kept while zoomed.
            canvas.restingScaleOverride = layout.scale
            canvas.isAhead = !visible.contains(i)
            canvas.place(transform(forPage: i, from: window.origin), settled: settled)
            // A canvas new to its page or resized lays out now, at the placement it was just given, so its
            // first layout of tiles already shows the page.
            canvas.layoutIfNeeded()
        }
        updatePaperLayers(for: visible.filter { !liveIDs.contains(pages[$0].id) })
        updateCurrentPage(in: viewport)
    }

    /// A canvas for `page`: a spare one handed the page, or a new one while the pool isn't full yet.
    private func canvas(for page: CanvasDocument, frame: CGRect) -> CanvasView {
        let canvas: CanvasView
        if let spare = spareCanvases.popLast() {
            canvas = spare
            canvas.frame = frame
            canvas.show(page)
        } else {
            canvas = CanvasView(frame: frame, document: page, embedded: true)
            canvasesMade += 1
            canvas.controller = controller
            canvas.telemetry = telemetry
            canvas.apply(theme)
            pageContainer.addSubview(canvas)
        }
        canvases[page.id] = canvas
        return canvas
    }

    /// `canvas`'s page left view: it leaves its tiles with the page and waits, hidden, for the next page.
    private func release(_ canvas: CanvasView) {
        if controller?.canvas === canvas {
            controller?.canvas = nil
        }
        canvas.leavePage()
        if spareCanvases.count < Self.maxLiveCanvases {
            spareCanvases.append(canvas)
        } else {
            canvas.removeFromSuperview()
        }
    }

    /// Follows the scroll's speed while it moves; a jump (`scroll(toPage:animated: false)`, a relayout)
    /// or a stop resets it.
    private func trackScrollVelocity() {
        let now = CACurrentMediaTime(), y = viewportInLayout.minY
        defer { lastScrollSample = (y, now) }
        guard isMoving, !scrollView.isZooming, let last = lastScrollSample, now > last.time, now - last.time < 0.1
        else {
            scrollVelocity = 0
            return
        }
        let measured = (y - last.y) / CGFloat(now - last.time)
        scrollVelocity = scrollVelocity * 0.5 + measured * 0.5
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
        for canvas in canvases.values + spareCanvases {
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
        trackScrollVelocity()
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
        scrollVelocity = 0
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
