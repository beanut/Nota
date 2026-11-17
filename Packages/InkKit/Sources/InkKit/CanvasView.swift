import SwiftUI
import UIKit

/// Raw-touch drawing surface.
///
/// Layers, bottom to top:
///  1. `pageLayer` and `templateTiles` – the paper and its template (the background).
///  2. `objectTiles` – the page's objects (see `PageObject`), then `objectFloat`, the ones being moved or drawn.
///     The template and objects are page-space tiles like the ink, drawn off the main thread into the
///     shared `TileCache` (`VectorTileLayer`, NOT-109).
///  3. `coordinator.layer` – the committed ink: finished strokes in page-space tiles, filled off the main
///     thread by the `RenderCoordinator` into the shared `TileCache`.
///  4. `liveView` – the in-progress stroke and pending strokes awaiting background rasterization and
///     late estimated property updates, in a grid of tile layers (see `LiveInkView`).
///  5. `tapeView` – the page's tape, which covers the ink (`TapeObject`): `tapeTiles` and `tapeFloat`; then
///     the laser (`LaserView`).
///  6. `lassoOverlayView` – the lasso, the selection box and its handles (the overlay), then the ruler.
final class CanvasView: UIView {
    /// The page, the desk around it and the lasso's accent, from the editor's `InkTheme` (see `apply(_:)`).
    private(set) var paperColor = InkTheme.standard.paper
    private var deskColor = InkTheme.standard.desk
    private(set) var accentColor = InkTheme.standard.accent
    private var shadowColor = InkTheme.standard.shadow
    private(set) var paperTheme = InkTheme.standard

    /// The page shown. An embedded canvas is handed another page as pages scroll in and out of view
    /// (`show(_:)`, NOT-107); otherwise it's the page the view was made with.
    private(set) var document: CanvasDocument
    /// True when the view is one page among several in continuous scrolling (`ContinuousCanvasView`): the
    /// host places the page (`place(_:settled:)`) and does the scrolling and zooming, and the view is
    /// transparent outside its page so the pages around it show through.
    let isEmbedded: Bool
    /// Where the host has put the page, while embedded.
    var placement = ViewTransform()
    /// While embedded, whether the host is still moving the page (`place(_:settled:)`).
    var placementMoving = false
    /// While embedded, true when the page isn't on screen yet but is about to be: the host gave it a
    /// canvas ahead of the scroll, and its tiles fill behind those of the pages on screen.
    var isAhead = false {
        didSet {
            if isAhead != oldValue {
                coordinator.rendersAheadDidChange()
            }
        }
    }

    /// The scale whose tiles the committed layer keeps while zoomed (set by a host that zooms the page
    /// itself, as continuous scrolling does); nil: the fitted page's.
    var restingScaleOverride: CGFloat?
    weak var controller: CanvasController? {
        didSet { pencilSettingsDidChange() }
    }

    weak var telemetry: PencilTelemetry?

    /// The pan and zoom, and the gestures moving it (see `CanvasView+Viewport`).
    var viewport = CanvasViewport()
    /// Set by the view's own pan and zoom, or by the host while embedded (`place(_:settled:)`).
    var viewTransform: ViewTransform {
        get { viewport.transform }
        set { viewport.transform = newValue }
    }

    /// The committed ink: its surface, geometry cache, strokes waiting to be drawn and render requests.
    /// One per page shown: an embedded canvas handed another page gets a new one, over the same layers.
    private(set) var coordinator: RenderCoordinator
    /// True when the committed layer shows the page as it is, sharp at the current transform: its tiles in
    /// view are at the transform's own level and the page's revision, and no fill of a tile in view or
    /// finished stroke is on its way (the margin around the view may still be filling). What the canvas benchmarks wait for after an edit,
    /// a gesture or a page entering view.
    var rendersSettled: Bool {
        coordinator.isSettled
    }

    /// Drives the short slide back to the fitted page after a swipe that didn't turn the page.
    var settleLink: CADisplayLink?

    private let pageLayer = CALayer()
    /// The paper and template shown, and the tiles they're drawn into.
    private(set) var paper = TemplatePaper()
    let templateTiles = VectorTileLayer()
    /// Holds the template and object layers, under the ink.
    private let underInkView = UIView()
    /// Holds the ink layers; masked to the page so strokes running off the edge are clipped.
    private let inkClipView = UIView()
    private let inkMask = CAShapeLayer()
    private var fittedBoundsSize = CGSize.zero
    let liveView = LiveInkView()
    /// True while this view is changing the document itself (see `editDocument`).
    private var isEditingDocument = false

    /// The touch drawing the stroke, erase or lasso under way.
    var activeTouch: UITouch?
    /// The group of a stroke carried across pages (`CanvasDocument.editGroup`), while it's under way here.
    var strokeGroup: UUID?
    /// Whether this page joined the stroke under way from another page, rather than a touch beginning it here.
    var joinedStroke = false
    var live: LiveStroke?
    var eraseSession: EraseSession?

    /// Lasso state
    enum LassoSession {
        case drawing([CGPoint]) // canvas-space gesture path
        case transforming(SelectionDrag) // dragging the selection or one of its handles
        case reshaping(ShapeReshape) // dragging one of a selected shape's handles
    }

    /// A drag of the selection: which handle, from where, the box and the strokes and objects as they
    /// were when it began, and the transform so far (from `start` to the latest sample).
    struct SelectionDrag {
        let handle: SelectionHandle
        let start: CGPoint
        let box: SelectionBox
        let session: CanvasDocument.TransformSession
        var transform: CGAffineTransform = .identity
    }

    /// A stroke snapped to a shape while the Pencil is still down (hold-to-snap); see `CanvasView+Shapes`.
    var shapeSnap: ShapeSnap?
    /// The text box being edited, while one is (see `CanvasView+Text`).
    var textEditor: TextBoxEditor?
    /// The picture being cropped, while one is (see `CanvasView+Images`).
    var imageCropView: ImageCropView?
    /// A text tool touch in progress.
    var textGesture: TextGesture?
    /// A tape or laser tool touch in progress (see `CanvasView+Tools`).
    var toolGesture: ToolGesture?
    /// The ruler edge the stroke being drawn snaps to, and what it has measured (see `CanvasView+Ruler`).
    var rulerSnap: RulerMeasurement?
    /// A finger tap with the text tool when fingers don't draw, or on the page while a box is edited.
    lazy var textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextFingerTap(_:)))

    var lassoPending = false // lasso touch began, first sample not yet seen
    var lassoSession: LassoSession?
    var selection = PageSelection.empty
    var selectionBox: SelectionBox? // canvas space; nil when nothing is selected
    /// The page's objects under the ink, in tiles; the ones being moved or drawn float over them.
    let objectTiles = VectorTileLayer()
    let objectFloat = FloatingObjectsLayer()
    /// Tape: objects drawn over the ink (`PageObject.drawsOverInk`), in tiles and floating, in `tapeView`.
    let tapeTiles = VectorTileLayer()
    let tapeFloat = FloatingObjectsLayer()
    let tapeView = UIView()
    let lassoOverlayView = LassoOverlayView()
    /// How many times each clip has been pasted on this page in its own place, so the next paste of it
    /// lands a step further along (see `PastePlacement`).
    var pasteCounts: [UUID: Int] = [:]
    /// The selection's menu (cut, copy, colour, arrange…) and the lasso's Paste menu.
    lazy var editMenu = UIEditMenuInteraction(delegate: self)
    /// Where a Paste from the lasso's Paste menu goes, in canvas space.
    var pendingPastePoint: CGPoint?
    /// Whether something was selected when the current lasso gesture began: a tap on nothing then only
    /// deselects, while a tap on nothing with nothing selected offers Paste.
    var lassoHadSelection = false
    /// Drags the selection out to other apps as an image.
    lazy var selectionDragInteraction = UIDragInteraction(delegate: self)
    /// A finger tap with the lasso, when fingers don't draw: shows the selection's menu or Paste.
    lazy var lassoTap = UITapGestureRecognizer(target: self, action: #selector(handleLassoTap(_:)))
    /// Palm rejection, finger ink and the samples waiting for refined estimates (see `CanvasView+Input`).
    var input = CanvasInput()
    var hoverActive = false
    /// Where the Pencil hovers, in view points, while it does.
    private var hoverLocation: CGPoint?

    // HUD
    var hud = PencilTelemetry.Snapshot()
    var sampleRate = RateCounter()
    var eventRate = RateCounter()

    // Scribble gestures
    /// Checks for circle-and-hold while ink is being drawn; runs only while a stroke is live.
    var holdTimer: Timer?
    var lastMovement: (location: CGPoint, time: TimeInterval)?
    lazy var feedback = UICanvasFeedbackGenerator(view: self)

    // Zoom window: the box on the page, the writing panel that magnifies it, and the panel's renders.
    enum ZoomMove { case back, advance, newLine }
    var zoomWindow: ZoomWindow?
    var zoomPanel: ZoomPanelView?
    var zoomBoxView: ZoomBoxOverlayView?
    var zoomGeneration: UInt64 = 0
    var zoomRenderScheduled = false
    /// The newest render of the panel shown so far: an older one landing later is dropped.
    var zoomShownGeneration: UInt64 = 0
    /// Strokes that ended while the panel was showing, kept on the panel's live layer until a render of
    /// the box includes them, so they never blink out.
    var zoomHeld: [LiveStroke] = []
    /// A touch dragging the box by its tab or resizing it by its knob.
    var zoomTouch: UITouch?
    var zoomDrag: ZoomDrag?
    /// What the active touch's locations are mapped through onto the page: the page's own transform, or the
    /// panel's when the stroke began in the panel.
    var inputTransform = ViewTransform()
    var inputInZoomPanel = false

    lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

    init(frame: CGRect, document: CanvasDocument, embedded: Bool = false) {
        self.document = document
        isEmbedded = embedded
        coordinator = RenderCoordinator(document: document, embedded: embedded)
        super.init(frame: frame)
        coordinator.host = self
        WaxRenderer.prewarm()
        backgroundColor = embedded ? .clear : deskColor
        isMultipleTouchEnabled = true

        pageLayer.shadowColor = shadowColor.cgColor
        pageLayer.shadowOpacity = 0.18
        pageLayer.shadowRadius = 6
        pageLayer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(pageLayer)
        for view in [underInkView, tapeView] {
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        underInkView.layer.addSublayer(templateTiles.layer)
        underInkView.layer.addSublayer(objectTiles.layer)
        underInkView.layer.addSublayer(objectFloat.layer)
        tapeView.layer.addSublayer(tapeTiles.layer)
        tapeView.layer.addSublayer(tapeFloat.layer)
        addSubview(underInkView)

        inkClipView.isUserInteractionEnabled = false
        inkClipView.backgroundColor = .clear
        inkClipView.layer.mask = inkMask
        addSubview(inkClipView)

        inkClipView.layer.addSublayer(coordinator.layer)

        // The opaque backdrop the live layer previews multiply ink over: the paper, then the template and
        // objects as their tiles show them.
        liveView.drawPaper = { [weak self] ctx, transform, rect in
            guard let self else { return }
            ctx.setFillColor(paper.palette.surface)
            ctx.fill(transform.toView(document.pageBounds).intersection(rect))
            templateTiles.draw(in: ctx, at: transform, viewRect: rect)
            objectTiles.draw(in: ctx, at: transform, viewRect: rect)
        }
        templateTiles.onPublish = { [weak self] in self?.vectorTilesDidPublish() }
        objectTiles.onPublish = { [weak self] in self?.vectorTilesDidPublish() }
        liveView.entries = { [weak self] in self?.liveEntries() ?? [] }
        inkClipView.addSubview(liveView)
        addSubview(tapeView)

        lassoOverlayView.canvas = self
        addSubview(lassoOverlayView)

        setUpGestures()
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        observeDocument()
        applyPaper()
        refreshObjects()
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(imageDidLoad(_:)),
                                               name: ImageAssets.didLoadImageNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeDocument() {
        document.addObserver(self, onChange: { [weak self] change in
            self?.documentDidChange(change)
        }, onPageSizeChange: { [weak self] in
            self?.resetView()
            self?.applyPaper()
            self?.refreshObjects()
        }, onTemplateChange: { [weak self] in
            self?.applyPaper()
        })
    }

    /// Embedded: the page left view, and the canvas waits to be handed another (`show(_:)`), hidden. What
    /// belonged to the page (a text box being edited, a picture being cropped, the selection) is finished,
    /// its tiles are left with it (`captureTileRaster`, NOT-106), and its coordinator stops: nothing of the
    /// page is held on screen or filled any more. Never while the page is taking ink.
    func leavePage() {
        guard isEmbedded, !hasLeftPage, !isInking else { return }
        endEditingText()
        finishImageCrop(commit: true)
        clearSelection()
        dismissEditMenu()
        coordinator.captureTileRaster()
        coordinator.retire()
        document.removeObserver(self)
        hasLeftPage = true
        isHidden = true
        // Hidden, its layers hold nothing: the next page's tiles are shown (or drawn) when it comes.
        for tiles in [templateTiles, objectTiles, tapeTiles] {
            tiles.clear()
        }
        for float in [objectFloat, tapeFloat] {
            float.show([])
        }
        lassoOverlayView.layer.contents = nil
    }

    /// Embedded: shows `newDocument` in place of the page shown, keeping the view, its layers, gestures and
    /// interactions, as continuous scrolling hands a canvas from a page leaving view to one entering it
    /// (NOT-107). The page shown is left first (`leavePage()`) if it hasn't been. The committed ink gets a
    /// new coordinator for the new page, over the old one's layers.
    func show(_ newDocument: CanvasDocument) {
        guard isEmbedded, newDocument !== document || hasLeftPage, !isInking else { return }
        leavePage()
        let old = coordinator
        document = newDocument
        coordinator = RenderCoordinator(document: newDocument, embedded: true, reusingLayersOf: old)
        coordinator.host = self
        observeDocument()
        hasLeftPage = false
        isHidden = false
        // Nothing of the old page's input, selection or placement carries over.
        live = nil
        eraseSession = nil
        lassoSession = nil
        lassoPending = false
        shapeSnap = nil
        rulerSnap = nil
        textGesture = nil
        toolGesture = nil
        strokeGroup = nil
        joinedStroke = false
        selection = .empty
        selectionBox = nil
        pasteCounts = [:]
        pendingPastePoint = nil
        input = CanvasInput()
        placement = ViewTransform()
        placementMoving = false
        isAhead = false
        fittedBoundsSize = .zero
        applyPaper()
        refreshObjects()
        invalidateAllLive()
        updateLassoOverlay()
        setNeedsLayout()
    }

    /// Set by `leavePage()` until the canvas is handed a page again.
    private(set) var hasLeftPage = false

    /// Disable the system's three-finger undo/redo/copy gestures; we drive undo ourselves.
    override var canBecomeFirstResponder: Bool {
        true
    }

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Before leaving the window, while the fitted transform still sees the real safe area. Embedded
        // pages too, as they scroll away: they leave their tiles at the column's zoom 1 (NOT-106).
        if newWindow == nil, window != nil {
            endEditingText()
            coordinator.captureTileRaster()
        }
    }

    /// The app may be ended in the background: leaves the page's tiles for it to keep (NOT-106).
    @objc func appDidEnterBackground() {
        guard window != nil else { return }
        coordinator.captureTileRaster()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        pencilSettingsDidChange() // Only Draw with Apple Pencil may have changed while away
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }

    /// Takes the page, desk, shadow and lasso colours from `theme`.
    func apply(_ theme: InkTheme) {
        // Called on every SwiftUI update; the theme rarely changes.
        guard theme.paper != paperColor || theme.desk != deskColor || theme.accent != accentColor
            || theme.shadow != shadowColor || theme.paperPalettes != paperTheme.paperPalettes
        else { return }
        paperColor = theme.paper
        paperTheme = theme
        deskColor = theme.desk
        accentColor = theme.accent
        shadowColor = theme.shadow
        backgroundColor = isEmbedded ? .clear : deskColor
        pageLayer.shadowColor = shadowColor.resolvedColor(with: traitCollection).cgColor
        applyPaper()
        lassoOverlayView.setNeedsDisplay()
        zoomPanel?.apply(theme, traits: traitCollection)
        zoomBoxView?.apply(theme, traits: traitCollection)
    }

    /// Colours the page with its template's paper and shows the template.
    private func applyPaper() {
        paper = TemplatePaper(template: document.template, artwork: document.templateArtwork,
                              palette: paperTheme.palette(for: document.template.paper), pageSize: document.pageSize)
        templateTiles.show(paper.tileContent())
        let surface = paper.palette.surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.backgroundColor = surface
        CATransaction.commit()
        liveView.paperColor = surface
        liveView.invalidateAll()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        inkClipView.frame = bounds
        underInkView.frame = bounds
        tapeView.frame = bounds
        liveView.frame = bounds
        lassoOverlayView.frame = bounds
        layoutZoomPanel()
        if bounds.size != fittedBoundsSize, bounds.width > 0, bounds.height > 0 {
            // First layout or a rotation / split-view resize: show the whole page again. Embedded, the host
            // places the page: a canvas resized mid-pinch (or made for a page entering view) stays where it
            // was put, rather than drawing its page fitted to its new size over the pages around it.
            fittedBoundsSize = bounds.size
            viewTransform = isEmbedded ? placement : fittedTransform()
            liveView.settle(at: viewTransform)
            coordinator.updateLayerTransform()
            reportZoom()
        }
        updateZoomWindow()
        updatePageChrome()
        coordinator.resize(to: bounds, scale: displayScale)
        updateVectorLayers()
    }

    /// Device pixels per point the view draws at.
    var displayScale: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    }

    func dropOrphanedPendingStrokes() {
        let strokeIDs = Set(document.strokes.map(\.id))
        coordinator.dropPending(notIn: strokeIDs)
        pruneSelection(strokeIDs: strokeIDs)
        zoomHeld.removeAll { !strokeIDs.contains($0.stroke.id) }
        invalidateAllLive()
        updateLassoOverlay()
    }

    /// `dropOrphanedPendingStrokes()` when the strokes that left the page are known (live erasing), so the
    /// rest of the page isn't looked at.
    func dropOrphanedPendingStrokes(removed: Set<UUID>) {
        coordinator.dropPending(removed)
        if !selection.strokeIDs.isDisjoint(with: removed) {
            selection.strokeIDs.subtract(removed)
            updateSelectionBox()
        }
        zoomHeld.removeAll { removed.contains($0.stroke.id) }
        invalidateAllLive()
        updateLassoOverlay()
    }

    /// Drops strokes and objects that are no longer on the page from the selection.
    func pruneSelection(strokeIDs: Set<UUID>? = nil) {
        guard !selection.isEmpty else { return }
        let strokeIDs = strokeIDs ?? Set(document.strokes.map(\.id))
        let objectIDs = Set(document.objects.map(\.id))
        guard !selection.strokeIDs.isSubset(of: strokeIDs) || !selection.objectIDs.isSubset(of: objectIDs) else { return }
        selection.strokeIDs.formIntersection(strokeIDs)
        selection.objectIDs.formIntersection(objectIDs)
        updateSelectionBox()
    }

    // MARK: - Object layer

    /// Shows the document's objects as they are now: in their tiles, but for those being moved (a selection
    /// dragged) or drawn (a shape, tape), which float over them until they're back in their tiles.
    func refreshObjects() {
        let preview: [any PageObject] = (shapeSnap.map { [$0.shape] } ?? []) + toolGesturePreview
        // The box being edited is shown by its text view instead.
        let editing = textEditor?.objectID ?? imageCropView?.objectID
        var lifted: [any PageObject] = [], moved = CGAffineTransform.identity
        if case let .transforming(drag)? = lassoSession {
            lifted = drag.session.objects
            moved = drag.transform
        }
        let liftedIDs = Set(lifted.map(\.id))
        let objects = document.objects.filter { $0.id != editing && !liftedIDs.contains($0.id) }
        let layers = objects.splitByInkLayer
        objectTiles.show(document.objectTileHistory.content(for: layers.under, pageBounds: document.pageBounds))
        tapeTiles.show(document.tapeTileHistory.content(for: layers.over, pageBounds: document.pageBounds))
        let floating = (lifted.isEmpty ? preview : lifted).splitByInkLayer
        if lifted.isEmpty {
            moved = .identity
        }
        float(floating.under, moved: moved, on: objectFloat, over: objectTiles)
        float(floating.over, moved: moved, on: tapeFloat, over: tapeTiles)
        placeFloatingObjects()
    }

    /// Shows `objects` floating over `tiles`. When they go (back into their tiles, or dropped), they stay
    /// until the tiles are drawn, so an object put down never blinks out.
    private func float(_ objects: [any PageObject], moved: CGAffineTransform, on float: FloatingObjectsLayer,
                       over tiles: VectorTileLayer) {
        guard objects.isEmpty, float.isShowing else {
            float.show(objects, moved: moved)
            return
        }
        let generation = float.generation
        tiles.whenSettled { [weak self, weak float] in
            guard let self, let float, float.generation == generation else { return }
            float.show([])
            placeFloatingObjects()
        }
    }

    private func placeFloatingObjects() {
        for float in [objectFloat, tapeFloat] {
            float.place(at: viewTransform, pageBounds: document.pageBounds, viewBounds: bounds, scale: displayScale)
        }
    }

    /// Lays the template, object and tape tiles and the floating objects out at the current transform.
    func updateVectorLayers() {
        let moving = isMoving, resting = restingScale
        for tiles in [templateTiles, objectTiles, tapeTiles] {
            tiles.update(transform: viewTransform, size: bounds.size, scale: displayScale, moving: moving,
                         restingScale: resting)
        }
        placeFloatingObjects()
    }

    /// True when the template, object and tape tiles show the page as it is, sharp at the current transform.
    var vectorLayersSettled: Bool {
        templateTiles.isSettled && objectTiles.isSettled && tapeTiles.isSettled
    }

    /// The template or objects on screen changed: the live layer's multiply backdrop is drawn from them.
    private func vectorTilesDidPublish() {
        guard !liveView.underlay.isEmpty else { return }
        liveView.underlay = coordinator.underlay
    }

    /// A picture finished decoding at a size the page's tiles want: where it's drawn, they're drawn again.
    @objc private func imageDidLoad(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? ImageAssetID else { return }
        var changed = false
        for history in [document.objectTileHistory, document.tapeTileHistory] {
            let rect = history.reach(ofObjectsUsing: [id])
            if !rect.isNull {
                history.invalidate(rect)
                changed = true
            }
        }
        if changed {
            refreshObjects()
        }
    }

    /// Drops the stroke being drawn without committing it (it became a shape or a selection).
    func discardLiveStroke() {
        live = nil
        invalidateAllLive()
    }

    // MARK: - Live layer

    /// What the live layer shows, bottom to top: pending strokes in commit order, then the active stroke.
    private func liveEntries() -> [LiveInkView.Entry] {
        var entries: [LiveInkView.Entry] = []
        let pending = coordinator.pending
        entries.reserveCapacity(pending.count + 1)
        for stroke in pending.map(\.live) + (live.map { [$0] } ?? []) {
            entries.append(LiveInkView.Entry(
                stroke: stroke,
                previewFill: stroke.stroke.brush.erases ? liveView.paperColor : nil
            ))
        }
        return entries
    }

    /// The selection box as it's shown now: moved with the drag while one is under way.
    private var displayedSelectionBox: SelectionBox? {
        if case let .transforming(drag)? = lassoSession {
            return drag.box.applying(drag.transform)
        }
        return selection.isEmpty ? nil : selectionBox
    }

    func drawLassoOverlay(in ctx: CGContext) {
        let accent = accentColor
        if let box = displayedSelectionBox {
            drawSelection(box, accent: accent, in: ctx)
        }
        drawTextDraft(in: ctx, accent: accent)
        if case let .drawing(pts)? = lassoSession,
           let polygon = LassoGeometry.region(mode: controller?.lassoMode ?? .freeform, points: pts)
           ?? (pts.count >= 2 ? pts : nil) {
            let path = CGMutablePath()
            path.addLines(between: polygon, transform: viewTransform.affine)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(accent.withAlphaComponent(0.10).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    func updateLassoOverlay() {
        lassoOverlayView.setNeedsDisplay()
    }

    func invalidateLive(canvasRect: CGRect) {
        liveView.invalidate(canvasRect: canvasRect)
        zoomPanel?.liveView.invalidate(canvasRect: canvasRect)
    }

    func invalidateAllLive() {
        liveView.invalidateAll()
        zoomPanel?.liveView.invalidateAll()
    }

    // MARK: - Commands

    /// Runs `body`, which edits the document, so this view doesn't treat the change as another view's.
    func editDocument<T>(_ body: () -> T) -> T {
        isEditingDocument = true
        defer { isEditingDocument = false }
        return body()
    }

    private func documentDidChange(_ change: CanvasDocument.Change) {
        if !isEditingDocument {
            // Another view showing the same page (the note open in a second window) changed it.
            redrawFromDocument(ink: change != .objectsEdited)
        }
        if change == .edited || change == .objectsEdited, isActiveCanvas {
            controller?.documentDidChange(canUndo: document.canUndo, canRedo: document.canRedo)
        }
    }

    /// Redraws the page from the document after it changed under the view (an undo, a redo, or an edit
    /// made in another view): the objects always, and the committed ink layer when the ink changed.
    func redrawFromDocument(ink: Bool = true) {
        if ink {
            coordinator.discardInFlight()
            invalidateMoved()
            dropOrphanedPendingStrokes()
            coordinator.invalidateAll()
        } else {
            pruneSelection()
        }
        refreshObjects()
        if !selection.isEmpty {
            updateSelectionBox()
        }
    }

    func clearCanvas() {
        endEditingText()
        editDocument { document.clear() }
        coordinator.discardInFlight()
        dropOrphanedPendingStrokes()
        pruneSelection()
        refreshObjects()
        coordinator.invalidateAll()
    }

    func resetView() {
        updateZoomWindow()
        viewTransform = isEmbedded ? placement : fittedTransform() // embedded, the host places the page
        liveView.settle(at: viewTransform)
        coordinator.updateLayerTransform()
        updatePageChrome()
        updateLassoOverlay()
        coordinator.requestRender()
        reportZoom()
    }

    // MARK: - Page

    /// The page rectangle in view coordinates at the current pan/zoom.
    var pageFrameInView: CGRect {
        viewTransform.toView(document.pageBounds)
    }

    /// Moves the paper and the ink clip to follow the page.
    func updatePageChrome() {
        let frame = pageFrameInView
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.frame = frame
        pageLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
        updateVectorLayers()
        placeTextEditor()
        placeImageCrop()
        inkMask.frame = inkClipView.bounds
        inkMask.path = CGPath(rect: frame, transform: nil)
        if let zoomBoxView, let zoomWindow {
            zoomBoxView.frame = bounds
            zoomBoxView.show(box: viewTransform.toView(zoomWindow.box))
        }
        CATransaction.commit()
    }

    /// Refits the page after the editor moved its floating chrome.
    func pageMarginsDidChange() {
        fittedBoundsSize = .zero
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        fittedBoundsSize = .zero // refit with the new insets on the next layout
        setNeedsLayout()
    }
}

// MARK: - Gestures

extension CanvasView {
    private func setUpGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        pan.allowedTouchTypes = direct // the Pencil never pans
        pan.minimumNumberOfTouches = fingerDraws ? 2 : 1 // see `pencilSettingsDidChange()`
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        pinch.allowedTouchTypes = direct
        pinch.delegate = self
        addGestureRecognizer(pinch)
        // Embedded, the host's scroll view pans and zooms every page together.
        pan.isEnabled = !isEmbedded
        pinch.isEnabled = !isEmbedded

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.allowedTouchTypes = direct
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }

        // Two-finger tap = undo, three-finger tap = redo. Recognizes immediately on touch-up
        // with zero multi-tap delay and without conflicting with system 3-finger tap recognizers.
        let twoFingerTap = MultiFingerTapRecognizer(touchesRequired: 2, target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.delegate = self
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = MultiFingerTapRecognizer(touchesRequired: 3, target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.delegate = self
        addGestureRecognizer(threeFingerTap)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        lassoTap.allowedTouchTypes = direct
        lassoTap.delegate = self
        addGestureRecognizer(lassoTap)
        textTap.allowedTouchTypes = direct
        textTap.delegate = self
        addGestureRecognizer(textTap)
        installTapeTap()
        addInteraction(editMenu)
        installImageDrop()
        selectionDragInteraction.isEnabled = false // see `updateSelectionBox()`
        addInteraction(selectionDragInteraction)
    }

    @objc private func handleSwipe(_ g: UISwipeGestureRecognizer) {
        let needsRender = cancelIncidentalPanZoom()
        let changed = g.direction == .left ? undo() : redo()
        if needsRender, !changed {
            coordinator.requestRender()
        }
    }

    @objc private func handleTwoFingerTap(_ g: MultiFingerTapRecognizer) {
        guard g.state == .ended else { return }
        let needsRender = cancelIncidentalPanZoom()
        if !undo(), needsRender {
            coordinator.requestRender()
        }
    }

    @objc private func handleThreeFingerTap(_ g: MultiFingerTapRecognizer) {
        guard g.state == .ended else { return }
        let needsRender = cancelIncidentalPanZoom()
        if !redo(), needsRender {
            coordinator.requestRender()
        }
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        // Pencil hover reports a height above the glass; a trackpad pointer reports zero.
        let pencilHovering = (g.state == .began || g.state == .changed) && g.zOffset > 0
        if pencilHovering {
            hoverActive = true
            let altitude = g.altitudeAngle, azimuth = g.azimuthAngle(in: self), roll = g.rollAngle
            let location = g.location(in: self)
            hoverLocation = location
            // The writing hand is over the glass too: keep rejecting palms near it.
            input.palmRejector.pencilSeen(at: location, time: ProcessInfo.processInfo.systemUptime)
            hud.altitude = altitude
            hud.azimuth = azimuth
            hud.roll = roll
            hud.zOffset = g.zOffset
            if activeTouch == nil {
                hud.state = .hovering
                let inPanel = zoomPanel != nil && zoomInkFrameInView.contains(location)
                let transform = inPanel ? zoomInputTransform : viewTransform
                setCursor(tipOutline(at: transform.toCanvas(location), altitude: altitude, azimuth: azimuth,
                                     roll: roll, transform: transform), inZoomPanel: inPanel)
            }
            publishHUD(force: false)
        } else if hoverActive {
            hoverActive = false
            hoverLocation = nil
            hud.zOffset = 0
            if activeTouch == nil {
                setCursor(nil)
                hud.state = .idle
            }
            publishHUD(force: true)
        }
    }
}

// MARK: - Gesture delegate

extension CanvasView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UIHoverGestureRecognizer {
            return true
        }
        if activeTouch != nil || zoomTouch != nil || isOnRuler(g) {
            return false
        } // palm rejection: no panning while the Pencil is down; a gesture on the ruler is the ruler's
        if g is TapeTapGestureRecognizer {
            return tapeTapShouldBegin(g)
        }
        if g === pan || g === pinch, let panel = zoomPanel, panel.frame.contains(g.location(in: self)) {
            return false // the writing panel stays put
        }
        if g === pinch {
            return g.numberOfTouches == 2
        }
        if g === lassoTap {
            return controller?.tool == .lasso && !fingerDraws
        }
        if g === textTap {
            return !fingerDraws && (controller?.tool == .text || textEditor != nil)
        }
        return true
    }

    /// Palm rejection: a resting hand never pans, zooms, swipes or taps.
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !isPalm(touch) && !isInTextEditor(touch) && !isInImageCrop(touch)
    }

    /// Whether the touch landed in the text box being edited.
    func isInTextEditor(_ touch: UITouch) -> Bool {
        guard let textView = textEditor?.textView, let view = touch.view else { return false }
        return view.isDescendant(of: textView)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g is MultiFingerTapRecognizer, other is UISwipeGestureRecognizer {
            return false
        }
        if g is UISwipeGestureRecognizer, other is MultiFingerTapRecognizer {
            return false
        }
        return true
    }

    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRequireFailureOf _: UIGestureRecognizer) -> Bool {
        false
    }
}

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

// MARK: - Render coordinator host

extension CanvasView: RenderCoordinatorHost {
    var renderTransform: ViewTransform {
        viewTransform
    }

    var isMoving: Bool {
        isEmbedded ? placementMoving : viewport.activeGestureCount > 0 || settleLink != nil
    }

    var restingScale: CGFloat {
        restingScaleOverride ?? fittedTransform().scale
    }

    var renderBounds: CGRect {
        bounds
    }

    var rendersAhead: Bool {
        isAhead
    }

    var isEditingInk: Bool {
        eraseSession != nil || lassoSession != nil
    }

    var pencilLocation: CGPoint? {
        live?.stroke.points.last?.location
    }

    func hasOutstandingEstimates(for strokeID: UUID) -> Bool {
        input.estimates.isOutstanding(strokeID)
    }

    func renderCoordinatorNeedsLayout() {
        setNeedsLayout()
    }

    func renderCoordinatorDidPublish() {
        liveView.underlay = coordinator.underlay
        scheduleZoomRender()
    }

    func renderCoordinatorDidDrawPending(canvasRect: CGRect) {
        invalidateLive(canvasRect: canvasRect)
    }
}
