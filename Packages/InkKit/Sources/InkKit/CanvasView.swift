import SwiftUI
import UIKit

/// Raw-touch drawing surface.
///
/// Layers, bottom to top:
///  1. `pageLayer` and `templateView` – the paper and its template (the background).
///  2. `objectLayer` – the page's objects (see `PageObject`), drawn as vectors at the current transform.
///  3. `committedLayer` – cached bitmap of finished strokes rasterized asynchronously on `renderQueue`
///     via coalesced, non-blocking full re-renders and incremental commits.
///  4. `liveView` – the in-progress stroke and pending strokes awaiting background rasterization and
///     late estimated property updates, in a grid of tile layers (see `LiveInkView`).
///  5. `tapeLayer` – the page's tape, which covers the ink (`TapeObject`), then the laser (`LaserView`).
///  6. `lassoOverlayView` – the lasso, the selection box and its handles (the overlay), then the ruler.
final class CanvasView: UIView {
    /// The page, the desk around it and the lasso's accent, from the editor's `InkTheme` (see `apply(_:)`).
    private(set) var paperColor = InkTheme.standard.paper
    private var deskColor = InkTheme.standard.desk
    private(set) var accentColor = InkTheme.standard.accent
    private var shadowColor = InkTheme.standard.shadow
    private(set) var paperTheme = InkTheme.standard

    let document: CanvasDocument
    /// True when the view is one page among several in continuous scrolling (`ContinuousCanvasView`): the
    /// host places the page (`place(_:settled:)`) and does the scrolling and zooming, and the view is
    /// transparent outside its page so the pages around it show through.
    let isEmbedded: Bool
    /// Where the host has put the page, while embedded.
    var placement = ViewTransform()
    weak var controller: CanvasController? {
        didSet { pencilSettingsDidChange() }
    }

    weak var telemetry: PencilTelemetry?

    /// Set by the view's own pan and zoom, or by the host while embedded (`place(_:settled:)`).
    var viewTransform = ViewTransform()
    private(set) var bitmapTransform =
        ViewTransform() // transform the bitmap is / will be rendered at once queued jobs run; pending strokes draw with this
    private(set) var displayedTransform = ViewTransform() // transform of the image currently in committedLayer.contents
    private(set) var fullRenderInFlight = false
    private var fullRenderRequested = false
    private var modifiedSinceSnapshot = Set<UUID>()
    /// Strokes whose geometry was dropped while `warmGeometry` was building it in the background.
    private var modifiedSinceWarmup = Set<UUID>()
    /// The document revision the committed bitmap holds once every job queued on `renderQueue` has run,
    /// or nil when it holds something no revision describes: strokes mid-erase or mid-drag, a finished
    /// stroke not drawn into it yet, an edit that's waiting for a full render.
    private var bitmapRevision: Int?
    /// The newest published image known to hold the whole page, fitted, at `revision`. When the page
    /// closes it becomes the document's `CommittedRaster`, so reopening the page needn't fill every stroke.
    private var rasterCandidate: RenderedPage?
    private struct RenderedPage {
        let image: CGImage
        let revision: Int
        let transform: ViewTransform
    }

    private var gestureStartTransform = ViewTransform()
    private var activeGestureCount = 0
    private var didTransformInTouchSequence = false
    /// Most fingers down at once since the last time none were; a three-finger swipe is undo/redo, not a page turn.
    private var maxDirectTouchesInSequence = 0
    private var didPinchInSequence = false
    /// Total movement of the current pan, for page swipes (the recognizer's translation is reset every frame).
    private var panTranslation = CGPoint.zero
    /// Drives the short slide back to the fitted page after a swipe that didn't turn the page.
    private var settleLink: CADisplayLink?
    private var settleFrom = ViewTransform()
    private var settleTo = ViewTransform()
    private var settleStart: CFTimeInterval = 0
    private var isCancellingGesture = false

    private let pageLayer = CALayer()
    private let templateView = TemplateView()
    /// Holds the ink layers; masked to the page so strokes running off the edge are clipped.
    private let inkClipView = UIView()
    private let inkMask = CAShapeLayer()
    private var fittedBoundsSize = CGSize.zero
    private let committedLayer = CALayer()
    let liveView = LiveInkView()
    private let renderQueue = DispatchQueue(label: "InkCanvas.render", qos: .userInteractive)
    private var generation: UInt64 = 0
    /// True while this view is changing the document itself (see `editDocument`).
    private var isEditingDocument = false
    private var bitmap: CGContext?
    private var bitmapPixelSize = CGSize.zero
    private(set) var bitmapScale: CGFloat = 2
    private(set) var geometryCache: [UUID: StrokeGeometry] = [:]

    private final class PendingStroke {
        var live: LiveStroke
        var geometry: StrokeGeometry
        var bounds: CGRect
        var deadline: CFTimeInterval
        var submitted = false
        var geometryDirty = false
        /// The document's revision before the stroke was added, and with it added (and every estimate
        /// update since applied): drawing it takes a bitmap at the first to the second.
        let revisionBefore: Int
        var revisionAfter: Int

        init(live: LiveStroke, geometry: StrokeGeometry, deadline: CFTimeInterval, revisionBefore: Int,
             revisionAfter: Int) {
            self.live = live
            self.geometry = geometry
            bounds = geometry.bounds
            self.deadline = deadline
            self.revisionBefore = revisionBefore
            self.revisionAfter = revisionAfter
        }
    }

    private var pending: [PendingStroke] = []
    private var isCommitScheduled = false

    /// The touch drawing the stroke, erase or lasso under way.
    private(set) var activeTouch: UITouch?
    /// The group of a stroke carried across pages (`CanvasDocument.editGroup`), while it's under way here.
    var strokeGroup: UUID?
    /// Whether this page joined the stroke under way from another page, rather than a touch beginning it here.
    private(set) var joinedStroke = false
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
    let objectLayer = ObjectLayerView()
    /// Tape: objects drawn over the ink (`PageObject.drawsOverInk`).
    let tapeLayer = ObjectLayerView()
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
    private struct PointRef { let strokeID: UUID; let index: Int }
    private var pendingEstimates: [NSNumber: PointRef] = [:]
    private var outstandingEstimates: [UUID: Int] = [:]
    private var hoverActive = false
    /// Where the Pencil hovers, in view points, while it does.
    private var hoverLocation: CGPoint?

    // HUD
    private var hud = PencilTelemetry.Snapshot()
    private var sampleRate = RateCounter()
    private var eventRate = RateCounter()

    /// The last finger-ink sample, for the pressure faked from drag speed.
    private struct FingerSample {
        let location: CGPoint
        let time: TimeInterval
        let force: CGFloat
    }

    private var fingerPrevious: FingerSample?

    /// Palm rejection and finger drawing (see `PencilSettings`)
    private var palmRejector = PalmRejector()
    /// Direct touches judged to be a resting hand; nothing on the canvas reacts to them.
    private var palmTouches = Set<UITouch>()
    /// When the active stroke began, so a second finger landing soon after turns finger ink into a gesture.
    private var strokeBeganAt: TimeInterval = 0

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
    let zoomRenderQueue = DispatchQueue(label: "InkCanvas.zoomRender", qos: .userInteractive)
    var zoomBitmap: CGContext? // touched only on zoomRenderQueue
    var zoomGeneration: UInt64 = 0
    var zoomRenderScheduled = false
    var zoomRenderInFlight = false
    var zoomRenderRequested = false
    /// Strokes that ended while the panel was showing, kept on the panel's live layer until a render of
    /// the box includes them, so they never blink out.
    var zoomHeld: [LiveStroke] = []
    /// A touch dragging the box by its tab or resizing it by its knob.
    var zoomTouch: UITouch?
    var zoomDrag: ZoomDrag?
    /// What the active touch's locations are mapped through onto the page: the page's own transform, or the
    /// panel's when the stroke began in the panel.
    private(set) var inputTransform = ViewTransform()
    private(set) var inputInZoomPanel = false

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

    init(frame: CGRect, document: CanvasDocument, embedded: Bool = false) {
        self.document = document
        isEmbedded = embedded
        super.init(frame: frame)
        backgroundColor = embedded ? .clear : deskColor
        isMultipleTouchEnabled = true

        pageLayer.shadowColor = shadowColor.cgColor
        pageLayer.shadowOpacity = 0.18
        pageLayer.shadowRadius = 6
        pageLayer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(pageLayer)
        addSubview(templateView)
        addSubview(objectLayer)

        inkClipView.isUserInteractionEnabled = false
        inkClipView.backgroundColor = .clear
        inkClipView.layer.mask = inkMask
        addSubview(inkClipView)

        committedLayer.anchorPoint = .zero
        inkClipView.layer.addSublayer(committedLayer)

        templateView.provideBackdrop(for: liveView) { [weak self] ctx, transform, rect in
            self?.objectLayer.drawObjects(at: transform, viewRect: rect, in: ctx)
        }
        liveView.entries = { [weak self] in self?.liveEntries() ?? [] }
        inkClipView.addSubview(liveView)
        addSubview(tapeLayer)

        lassoOverlayView.canvas = self
        addSubview(lassoOverlayView)

        setUpGestures()
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        document.addObserver(self, onChange: { [weak self] change in
            self?.documentDidChange(change)
        }, onPageSizeChange: { [weak self] in
            self?.resetView()
            self?.applyPaper()
            self?.refreshObjects()
        }, onTemplateChange: { [weak self] in
            self?.applyPaper()
        })
        applyPaper()
        refreshObjects()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Disable the system's three-finger undo/redo/copy gestures; we drive undo ourselves.
    override var canBecomeFirstResponder: Bool {
        true
    }

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Before leaving the window, while the fitted transform still sees the real safe area.
        // Embedded pages come and go as they scroll by, at whatever transform they were at: no raster.
        if newWindow == nil, window != nil {
            endEditingText()
        }
        if newWindow == nil, window != nil, !isEmbedded {
            saveCommittedRaster()
        }
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
        let surface = templateView.show(document, theme: paperTheme)
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
        templateView.frame = bounds
        objectLayer.frame = bounds
        tapeLayer.frame = bounds
        liveView.frame = bounds
        lassoOverlayView.frame = bounds
        layoutZoomPanel()
        if bounds.size != fittedBoundsSize, bounds.width > 0, bounds.height > 0 {
            // First layout or a rotation / split-view resize: show the whole page again.
            fittedBoundsSize = bounds.size
            viewTransform = fittedTransform()
            liveView.settle(at: viewTransform)
            updateCommittedLayerTransform()
            reportZoom()
        }
        updateZoomWindow()
        updatePageChrome()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let pixels = Self.pixelSize(of: bounds.size, scale: scale)
        guard pixels != bitmapPixelSize || scale != bitmapScale else { return }
        bitmapPixelSize = pixels
        bitmapScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedLayer.bounds = bounds
        committedLayer.position = .zero
        committedLayer.contentsScale = scale
        CATransaction.commit()
        makeBitmap()
        bitmapRevision = nil
        if !restoreCommittedRaster() {
            requestFullRender()
        }
    }

    // MARK: - Committed bitmap

    private static func pixelSize(of size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
    }

    private func makeBitmap() {
        let pixelSize = bitmapPixelSize
        let scale = bitmapScale
        renderQueue.sync {
            self.bitmap = CommittedRenderer.makeBitmap(pixelSize: pixelSize, scale: scale)
        }
    }

    /// Drops a stroke's cached geometry after the stroke changed.
    func forgetGeometry(_ id: UUID) {
        geometryCache[id] = nil
        modifiedSinceSnapshot.insert(id)
        modifiedSinceWarmup.insert(id)
    }

    func geometry(for stroke: Stroke) -> StrokeGeometry {
        if let g = geometryCache[stroke.id] {
            return g
        }
        let g = StrokeRenderer.geometry(for: stroke)
        geometryCache[stroke.id] = g
        return g
    }

    func requestFullRender() {
        // No bitmap for this size yet (a new view, or one just resized): making one (`layoutSubviews`)
        // renders, and rendering now would only fill the old one.
        guard bitmapPixelSize != .zero, bitmapPixelSize == Self.pixelSize(of: bounds.size, scale: bitmapScale) else {
            setNeedsLayout()
            return
        }
        if fullRenderInFlight {
            fullRenderRequested = true
        } else {
            startFullRender()
        }
    }

    private func startFullRender() {
        generation &+= 1
        let currentGeneration = generation
        fullRenderInFlight = true
        bitmapTransform = viewTransform
        modifiedSinceSnapshot.removeAll()

        let currentBounds = bounds
        let targetTransform = bitmapTransform

        let unsubmittedIDs = Set(pending.filter { !$0.submitted }.map(\.live.stroke.id))
        let renderedRevision = unsubmittedIDs.isEmpty && eraseSession == nil && lassoSession == nil
            ? document.revision : nil
        bitmapRevision = renderedRevision
        let itemsToRender = committedItems(skipping: unsubmittedIDs)

        let coveredPending = pending.filter(\.submitted)

        renderQueue.async { [weak self] in
            guard let self else { return }
            var computedGeometries: [(UUID, StrokeGeometry)] = []
            var image: CGImage?
            if let ctx = bitmap {
                computedGeometries = CommittedRenderer.render(itemsToRender, into: ctx, bounds: currentBounds,
                                                              transform: targetTransform)
                image = ctx.makeImage()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if generation == currentGeneration {
                    if let image {
                        publish(image: image, transform: targetTransform)
                    }
                    for (id, geom) in computedGeometries {
                        if geometryCache[id] == nil, !modifiedSinceSnapshot.contains(id) {
                            geometryCache[id] = geom
                        }
                    }
                    for item in coveredPending {
                        if let idx = pending.firstIndex(where: { $0 === item }) {
                            pending.remove(at: idx)
                        }
                        invalidateLive(canvasRect: item.bounds)
                    }
                    liveView.invalidateAll()
                    if let image {
                        noteRendered(image, revision: renderedRevision, transform: targetTransform)
                    }
                }
                fullRenderInFlight = false
                if fullRenderRequested {
                    fullRenderRequested = false
                    startFullRender()
                }
            }
        }
    }

    func updateCommittedLayerTransform() {
        let t: CGAffineTransform
        if displayedTransform == viewTransform {
            t = .identity
        } else {
            let k = viewTransform.scale / displayedTransform.scale
            t = CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                  tx: viewTransform.offset.x - displayedTransform.offset.x * k,
                                  ty: viewTransform.offset.y - displayedTransform.offset.y * k)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedLayer.setAffineTransform(t)
        CATransaction.commit()
    }

    private func publish(image: CGImage, transform: ViewTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedLayer.contents = image
        displayedTransform = transform
        updateCommittedLayerTransform()
        CATransaction.commit()
        liveView.underlay = image
        scheduleZoomRender()
    }

    // MARK: - Page raster

    /// Called with every image published from a render job that drew the page at `revision` (nil: not
    /// a whole revision). Keeps the newest whole, fitted one as the page's raster-to-be.
    private func noteRendered(_ image: CGImage, revision: Int?, transform: ViewTransform) {
        if !isEmbedded, let revision, revision == document.revision, bitmapRevision == revision, pending.isEmpty,
           !fullRenderRequested, transform == fittedTransform() {
            rasterCandidate = RenderedPage(image: image, revision: revision, transform: transform)
        } else if rasterCandidate?.revision != document.revision {
            rasterCandidate = nil // an older revision: no use to anyone, and it holds a screenful of pixels
        }
    }

    /// Puts the document's `CommittedRaster` into the fresh bitmap instead of a full render, when it
    /// shows the page as it is now at the transform and size the bitmap is for. Returns false if it can't.
    private func restoreCommittedRaster() -> Bool {
        guard let raster = document.committedRaster, !fullRenderInFlight, pending.isEmpty,
              raster.matches(revision: document.revision, pixelSize: bitmapPixelSize, scale: bitmapScale,
                             transform: viewTransform)
        else { return false }
        generation &+= 1
        let currentGeneration = generation
        let transform = viewTransform
        bitmapTransform = transform
        bitmapRevision = raster.revision
        renderQueue.async { [weak self] in
            guard let self, let ctx = bitmap else { return }
            let image = raster.restore(into: ctx) ? ctx.makeImage() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == currentGeneration else { return }
                guard let image else {
                    // Undecodable: draw the page the slow way after all.
                    document.committedRaster = nil
                    bitmapRevision = nil
                    requestFullRender()
                    return
                }
                publish(image: image, transform: transform)
                liveView.invalidateAll()
                noteRendered(image, revision: raster.revision, transform: transform)
                warmGeometry()
            }
        }
        return true
    }

    /// Builds, in the background, the geometry of every stroke that has none cached: a page opened from
    /// its raster drew none, and erasing, the lasso and the next full render all need it.
    private func warmGeometry() {
        let strokes = document.strokes.filter { geometryCache[$0.id] == nil }
        guard !strokes.isEmpty else { return }
        modifiedSinceWarmup.removeAll()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let geometries = CommittedRenderer.geometries(for: strokes)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (stroke, geometry) in zip(strokes, geometries)
                    where geometryCache[stroke.id] == nil && !modifiedSinceWarmup.contains(stroke.id) {
                    geometryCache[stroke.id] = geometry
                }
            }
        }
    }

    /// The page is going away: leaves its committed layer with the document as a `CommittedRaster` for
    /// the next time it opens. The pixels on screen are used when they're known to be the whole page as
    /// it is; otherwise the page is drawn again, fitted, in the background.
    private func saveCommittedRaster() {
        let revision = document.revision
        let transform = fittedTransform()
        let pixelSize = bitmapPixelSize, scale = bitmapScale
        let document = document
        guard pixelSize.width > 0, pixelSize.height > 0,
              !(document.committedRaster?.matches(revision: revision, pixelSize: pixelSize, scale: scale,
                                                  transform: transform) ?? false)
        else { return }
        let store: (CommittedRaster?) -> Void = { raster in
            DispatchQueue.main.async {
                guard let raster, document.revision == raster.revision else { return }
                document.committedRaster = raster
            }
        }
        if let candidate = rasterCandidate, candidate.revision == revision, candidate.transform == transform,
           eraseSession == nil, lassoSession == nil, pending.isEmpty, live == nil {
            DispatchQueue.global(qos: .utility).async {
                store(CommittedRaster(image: candidate.image, revision: revision, transform: transform, scale: scale))
            }
            return
        }
        guard document.strokes.contains(where: { !$0.brush.erases }) else { return }
        let items = committedItems()
        DispatchQueue.global(qos: .utility).async {
            store(CommittedRaster(rendering: items, pixelSize: pixelSize, scale: scale, transform: transform,
                                  revision: revision))
        }
    }

    /// The document's strokes to render, with their cached geometry where there is some.
    private func committedItems(skipping skipped: Set<UUID> = []) -> [CommittedRenderer.Item] {
        document.strokes.compactMap { stroke in
            guard !skipped.contains(stroke.id) else { return nil }
            let cached = geometryCache[stroke.id]
            return CommittedRenderer.Item(id: stroke.id, brush: stroke.brush, color: stroke.color,
                                          geometry: cached, stroke: cached == nil ? stroke : nil)
        }
    }

    private func submitPendingStroke(_ item: PendingStroke) {
        item.submitted = true
        let geom = item.live.geometry()
        item.geometry = geom
        item.bounds = geom.bounds
        geometryCache[item.live.stroke.id] = geom
        let runs = geom.runs
        let bounds = geom.bounds
        let brush = item.live.stroke.brush
        let color = item.live.stroke.color
        let targetTransform = bitmapTransform
        let currentGeneration = generation
        let isNext = bitmapRevision != nil && bitmapRevision == item.revisionBefore && item.revisionAfter >= 0
        bitmapRevision = isNext ? item.revisionAfter : nil
        let renderedRevision = bitmapRevision

        renderQueue.async { [weak self] in
            guard let self, let ctx = bitmap else { return }
            ctx.saveGState()
            ctx.concatenate(targetTransform.affine)
            if brush.usesPattern {
                PencilTexture.prepareContext(ctx, phase: targetTransform.offset)
            }
            StrokeRenderer.draw(runs: runs, clip: bounds.insetBy(dx: -2, dy: -2),
                                brush: brush, color: color, in: ctx)
            ctx.restoreGState()
            let image = ctx.makeImage()

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == currentGeneration, let image else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                publish(image: image, transform: targetTransform)
                if let idx = pending.firstIndex(where: { $0 === item }) {
                    pending.remove(at: idx)
                }
                invalidateLive(canvasRect: bounds)
                CATransaction.commit()
                noteRendered(image, revision: renderedRevision, transform: targetTransform)
            }
        }
    }

    private func schedulePendingCommit() {
        let now = CACurrentMediaTime()
        var hasWaiting = false

        for item in pending {
            if item.submitted {
                continue
            }
            let hasEstimates = (outstandingEstimates[item.live.stroke.id] ?? 0) > 0
            let ready = !hasEstimates || now >= item.deadline
            if ready {
                submitPendingStroke(item)
            } else {
                hasWaiting = true
                break
            }
        }

        if hasWaiting, !isCommitScheduled {
            isCommitScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self else { return }
                isCommitScheduled = false
                schedulePendingCommit()
            }
        }
    }

    private func decrementOutstandingEstimates(for strokeID: UUID) {
        if let count = outstandingEstimates[strokeID] {
            if count <= 1 {
                outstandingEstimates.removeValue(forKey: strokeID)
            } else {
                outstandingEstimates[strokeID] = count - 1
            }
        }
    }

    func dropOrphanedPendingStrokes() {
        let strokeIDs = Set(document.strokes.map(\.id))
        pending.removeAll { !strokeIDs.contains($0.live.stroke.id) }
        pruneSelection(strokeIDs: strokeIDs)
        zoomHeld.removeAll { !strokeIDs.contains($0.stroke.id) }
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

    /// Drops pending strokes that are about to be redrawn elsewhere (moved by the lasso or undone).
    func dropPending(_ ids: Set<UUID>) {
        pending.removeAll { ids.contains($0.live.stroke.id) }
    }

    // MARK: - Object layer

    /// Shows the document's objects as they are now.
    func refreshObjects() {
        let preview: [any PageObject] = (shapeSnap.map { [$0.shape] } ?? []) + toolGesturePreview
        // The box being edited is shown by its text view instead.
        let editing = textEditor?.objectID ?? imageCropView?.objectID
        let objects = editing.map { id in document.objects.filter { $0.id != id } } ?? document.objects
        let layers = (objects + preview).splitByInkLayer
        objectLayer.show(layers.under, pageBounds: document.pageBounds)
        tapeLayer.show(layers.over, pageBounds: document.pageBounds)
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

    private func invalidateLive(canvasRect: CGRect) {
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
            generation &+= 1
            invalidateMoved()
            dropOrphanedPendingStrokes()
            requestFullRender()
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
        generation &+= 1
        dropOrphanedPendingStrokes()
        pruneSelection()
        refreshObjects()
        requestFullRender()
    }

    func resetView() {
        updateZoomWindow()
        viewTransform = fittedTransform()
        liveView.settle(at: viewTransform)
        updateCommittedLayerTransform()
        updatePageChrome()
        updateLassoOverlay()
        requestFullRender()
        reportZoom()
    }

    // MARK: - Page

    /// The transform that fits the whole page between the margins; while embedded, where the host put it.
    func fittedTransform() -> ViewTransform {
        if isEmbedded {
            return placement
        }
        let s = safeAreaInsets, m = controller?.pageMargins ?? CanvasController.defaultPageMargins
        var insets = UIEdgeInsets(top: s.top + m.top, left: s.left + m.left,
                                  bottom: s.bottom + m.bottom, right: s.right + m.right)
        if zoomPanel != nil {
            // The page sits above the writing panel, so the zoom box is never under it.
            insets.bottom = bounds.maxY - zoomPanelFrame().minY + Self.zoomPanelGap
        }
        return ViewTransform.fitting(page: document.pageBounds, in: bounds, insets: insets,
                                     scaleRange: .leastNonzeroMagnitude ... .greatestFiniteMagnitude)
    }

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
        templateView.follow(viewTransform)
        objectLayer.follow(viewTransform)
        tapeLayer.follow(viewTransform)
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

    // MARK: - Touch input

    private func isDrawingTouch(_ touch: UITouch, event: UIEvent?) -> Bool {
        if touch.type == .pencil {
            return true
        }
        // A lone finger draws when finger drawing is on (by default in the simulator, which has no Pencil).
        guard fingerDraws, isFinger(touch) else { return false }
        let fingers = event?.allTouches?.filter { isFinger($0) && $0.phase != .ended && $0.phase != .cancelled }
        return (fingers?.count ?? 1) == 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Touches in the text box being edited are the text view's.
        let touches = touches.filter { !isInTextEditor($0) }
        guard !touches.isEmpty else { return }
        if !isFirstResponder, textEditor == nil {
            _ = becomeFirstResponder()
        }
        for touch in touches where touch.type == .pencil {
            palmRejector.pencilSeen(at: touch.location(in: self), time: touch.timestamp)
        }
        let priorDirectTouches = event?.allTouches?.filter {
            isFinger($0) && !touches.contains($0) && $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        // A second finger soon after finger ink began: it was the start of a pinch, pan or tap, not ink.
        if let active = activeTouch, active.type == .direct, let finger = touches.first(where: { isFinger($0) }),
           finger.timestamp - strokeBeganAt < 0.3 {
            endStroke(commit: false)
        }
        if priorDirectTouches == 0, activeGestureCount == 0, touches.contains(where: { isFinger($0) }) {
            gestureStartTransform = viewTransform
            didTransformInTouchSequence = false
        }
        if settleLink != nil {
            finishSettling()
        } // never draw on a page that's still sliding
        if priorDirectTouches == 0 {
            maxDirectTouchesInSequence = 0
            didPinchInSequence = false
        }
        let directTouches = priorDirectTouches + touches.filter { isFinger($0) }.count
        maxDirectTouchesInSequence = max(maxDirectTouchesInSequence, directTouches)
        for touch in touches {
            if activeTouch == nil, beginZoomDrag(touch) {
                continue
            }
            guard isDrawingTouch(touch, event: event), activeTouch == nil, activeGestureCount == 0,
                  zoomTouch == nil else { continue }
            activeTouch = touch
            if controller?.tool != .text {
                // Writing or erasing anywhere finishes the text box being edited.
                controller?.canvas?.endEditingText()
                endEditingText()
            }
            if isEmbedded {
                controller?.embeddedCanvasWillInk(self) // writing on a page makes it the one being worked on
            }
            strokeBeganAt = touch.timestamp
            let location = touch.preciseLocation(in: self)
            inputInZoomPanel = zoomPanel != nil && zoomInkFrameInView.contains(location)
            inputTransform = inputInZoomPanel ? zoomInputTransform : viewTransform
            beginStroke(at: inputTransform.toCanvas(location))
            startHoldWatch(at: location, time: touch.timestamp)
            ingest(touch, event: event, final: false)
            if isEmbedded, carriesAcrossPages {
                controller?.continuousHost?.beginWritingAcrossPages(touch, event: event, on: self)
            }
        }
        updateFingerState(event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = zoomTouch, touches.contains(touch) {
            updateZoomDrag(touch)
        }
        if let touch = activeTouch, touches.contains(touch) {
            moveStroke(touch, event: event)
        }
        handOnAcrossPages(touches, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = zoomTouch, touches.contains(touch) {
            endZoomDrag()
        }
        if let touch = activeTouch, touches.contains(touch) {
            ingest(touch, event: event, final: true)
            endStroke(commit: true)
        }
        handOnAcrossPages(touches, event: event, endingWith: true)
        updateFingerState(event, ending: touches)
        palmTouches.subtract(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = zoomTouch, touches.contains(touch) {
            endZoomDrag()
        }
        if let touch = activeTouch, touches.contains(touch) {
            endStroke(commit: false)
        }
        handOnAcrossPages(touches, event: event, endingWith: false)
        updateFingerState(event, ending: touches)
        palmTouches.subtract(touches)
    }

    /// The next event of the stroke under way.
    func moveStroke(_ touch: UITouch, event: UIEvent?) {
        if touch.type == .pencil {
            palmRejector.pencilSeen(at: touch.location(in: self), time: touch.timestamp)
        } else if isPalm(touch) {
            endStroke(commit: false) // finger ink whose contact grew into a palm
            return
        }
        ingest(touch, event: event, final: false)
    }

    /// Starts this page's piece of a stroke begun on another page (or of this page's own stroke, back
    /// after leaving it), as it comes within reach. The piece may start off the page.
    func joinStroke(_ touch: UITouch, event: UIEvent?, group: UUID) {
        guard activeTouch == nil, activeGestureCount == 0, zoomTouch == nil else { return }
        activeTouch = touch
        strokeGroup = group
        joinedStroke = true
        strokeBeganAt = touch.timestamp
        inputInZoomPanel = false
        inputTransform = viewTransform
        beginStroke(at: inputTransform.toCanvas(touch.preciseLocation(in: self)), offPage: true)
        ingest(touch, event: event, final: false)
    }

    /// Ends this page's piece: the stroke went out of reach, or it ended.
    func leaveStroke(_ touch: UITouch, event: UIEvent?, final: Bool, commit: Bool) {
        guard activeTouch === touch else { return }
        if final, commit {
            ingest(touch, event: event, final: true)
        }
        endStroke(commit: commit)
    }

    /// Pencil force/tilt are often first reported as estimates and refined a few ms later.
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        applyEstimates(touches, recording: true)
        // Pages that joined a stroke begun here hear about their samples' refinements from this page.
        if isEmbedded {
            controller?.continuousHost?.forwardEstimates(touches, from: self)
        }
    }

    /// Patches refined force and tilt into the live and committed strokes whose samples they belong to.
    func applyEstimates(_ touches: Set<UITouch>, recording: Bool) {
        var liveDirty = CGRect.null
        var liveTouchesTail = false
        var pendingDirty = CGRect.null
        for touch in touches {
            if recording, let recorder = controller?.inputRecorder, let key = touch.estimationUpdateIndex {
                let v = sampleValues(touch)
                recorder.update(estimationKey: key, force: v.force, altitude: v.altitude, azimuth: v.azimuth,
                                final: touch.estimatedPropertiesExpectingUpdates.isEmpty)
            }
            guard let key = touch.estimationUpdateIndex, let ref = pendingEstimates[key] else { continue }
            let refined = sampleValues(touch)
            let apply: (inout StrokePoint) -> Void = { p in
                p.force = refined.force
                p.altitude = refined.altitude
                p.azimuth = refined.azimuth
            }
            if let live, live.stroke.id == ref.strokeID, live.stroke.points.indices.contains(ref.index) {
                apply(&live.stroke.points[ref.index])
                let r = live.refreshPoint(ref.index)
                liveView.geometryChanged(of: live, fromSegment: ref.index - 1, canvasRect: r.dirty)
                zoomPanel?.liveView.geometryChanged(of: live, fromSegment: ref.index - 1, canvasRect: r.dirty)
                liveDirty = liveDirty.union(r.dirty)
                if r.touchesTail {
                    liveTouchesTail = true
                }
            } else if let pendingStroke = pending.first(where: { $0.live.stroke.id == ref.strokeID && !$0.submitted }),
                      pendingStroke.live.stroke.points.indices.contains(ref.index) {
                apply(&pendingStroke.live.stroke.points[ref.index])
                let wasCurrent = pendingStroke.revisionAfter == document.revision
                _ = editDocument { document.updatePoint(strokeID: ref.strokeID, index: ref.index, apply) }
                // Only while nothing else changed since: otherwise drawing it can't bring the bitmap level.
                pendingStroke.revisionAfter = wasCurrent ? document.revision : -1
                let r = pendingStroke.live.refreshPoint(ref.index)
                liveView.geometryChanged(of: pendingStroke.live, fromSegment: ref.index - 1, canvasRect: r.dirty)
                zoomPanel?.liveView.geometryChanged(of: pendingStroke.live, fromSegment: ref.index - 1,
                                                    canvasRect: r.dirty)
                var dirty = r.dirty
                if r.touchesTail {
                    dirty = dirty.union(pendingStroke.live.rebuildTail(predicted: []))
                }
                pendingDirty = pendingDirty.union(dirty)
                pendingStroke.geometryDirty = true
                forgetGeometry(ref.strokeID)
            } else if editDocument({ document.updatePoint(strokeID: ref.strokeID, index: ref.index, apply) }) {
                forgetGeometry(ref.strokeID)
                requestFullRender()
            }
            if touch.estimatedPropertiesExpectingUpdates.isEmpty {
                if let live, live.stroke.id == ref.strokeID {
                    live.unsettledPoints.remove(ref.index)
                } else {
                    pending.first { $0.live.stroke.id == ref.strokeID }?.live.unsettledPoints.remove(ref.index)
                }
                pendingEstimates[key] = nil
                decrementOutstandingEstimates(for: ref.strokeID)
            }
        }
        if let live {
            if liveTouchesTail {
                let tailDirty = live.rebuildTail(predicted: live.lastPredicted)
                liveDirty = liveDirty.union(tailDirty)
            }
            if !liveDirty.isNull {
                invalidateLive(canvasRect: liveDirty)
            }
        }
        for p in pending where p.geometryDirty {
            p.geometryDirty = false
            let newGeom = p.live.geometry()
            p.geometry = newGeom
            p.bounds = newGeom.bounds
            forgetGeometry(p.live.stroke.id)
        }
        if !pendingDirty.isNull {
            invalidateLive(canvasRect: pendingDirty)
        }
        schedulePendingCommit()
    }

    /// `start` is the touch-down point in canvas space. Ink only starts on the page; erasing and the
    /// lasso work from anywhere, since they may need to reach strokes hanging off the edge.
    private func beginStroke(at start: CGPoint, offPage: Bool = false) {
        guard let controller else { return }
        if pendingEstimates.count > 1024 {
            pendingEstimates.removeAll()
            outstandingEstimates.removeAll()
        }
        fingerPrevious = nil
        liveView.settle(at: viewTransform)
        if controller.tool.isGestureTool {
            beginToolGesture(at: start) // text, tape or the laser: no ink
        } else if controller.tool == .lasso {
            lassoPending = true
        } else if controller.tool == .eraser && controller.eraserMode != .precision {
            eraseSession = EraseSession(target: controller.effectiveEraserTarget,
                                        before: controller.eraserMode == .standard ? document.strokes : nil)
        } else if controller.tool == .eraser || offPage || document.contains(start) {
            let template = controller.strokeTemplate(viewScale: inputTransform.scale)
            let stroke = Stroke(id: UUID(), color: template.color, brush: template.brush, points: [])
            live = LiveStroke(stroke: stroke)
            beginRulerSnap(at: start)
            controller.inputRecorder?.begin(stroke, viewScale: inputTransform.scale, pageSize: document.pageSize)
        }
        if hoverActive {
            setCursor(nil)
        }
    }

    /// Feeds every coalesced sample since the last event (up to 240 Hz on Pencil, vs. the 120 Hz
    /// display-rate `touchesMoved`), then appends predicted samples as a throwaway preview tail.
    private func ingest(_ touch: UITouch, event: UIEvent?, final: Bool) {
        eventRate.record(touch.timestamp)
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            appendSample(sample)
        }

        if let live {
            noteMovement(at: touch.preciseLocation(in: self), time: touch.timestamp)
            // Predicted touches are never stored: the tail is rebuilt (and they're dropped) on the next real event.
            let predicted = final ? [] : (event?.predictedTouches(for: touch) ?? []).map { makePoint($0, predicted: true) }
            hud.predictedCount = predicted.count
            controller?.inputRecorder?.endEvent(strokeID: live.stroke.id, predicted: predicted)
            invalidateLive(canvasRect: live.advance(predicted: predicted))
            updateRulerReadout(live)
            if live.stroke.brush.erases, let last = live.stroke.points.last {
                showEraserCursor(at: last.location)
            }
        }
        hud.state = touch.type == .pencil ? .pencilDown : .simulatedPencil
        publishHUD(force: final)
    }

    private func appendSample(_ touch: UITouch) {
        let point = makePoint(touch, predicted: false)
        sampleRate.record(touch.timestamp)
        hud.force = touch.type == .pencil ? touch.force : point.force
        hud.maxForce = touch.type == .pencil ? touch.maximumPossibleForce : 1
        hud.normalizedForce = point.force
        hud.altitude = point.altitude
        hud.azimuth = point.azimuth
        hud.roll = touch.type == .pencil ? touch.rollAngle : 0

        if lassoPending || lassoSession != nil {
            handleLassoSample(point.location)
            return
        }
        if eraseSession != nil {
            eraseStrokes(along: point.location)
            return
        }
        if shapeSnap != nil {
            updateShapeSnap(to: point.location)
            return
        }
        if updateToolGesture(to: point.location) {
            return
        }
        guard let live else { return }
        let expectsUpdate = !touch.estimatedPropertiesExpectingUpdates.isEmpty
        controller?.inputRecorder?.sample(point, strokeID: live.stroke.id,
                                          estimationKey: expectsUpdate ? touch.estimationUpdateIndex : nil)
        // Near-duplicate samples (under 0.3 view points apart) only update the last point's pressure.
        guard let index = live.append(point, minSpacing: 0.3 / inputTransform.scale) else { return }
        if expectsUpdate, let key = touch.estimationUpdateIndex {
            if let old = pendingEstimates[key] {
                decrementOutstandingEstimates(for: old.strokeID)
            }
            pendingEstimates[key] = PointRef(strokeID: live.stroke.id, index: index)
            live.unsettledPoints.insert(index)
            outstandingEstimates[live.stroke.id, default: 0] += 1
        }
    }

    private struct TouchValues {
        let force: CGFloat
        let altitude: CGFloat
        let azimuth: CGFloat
    }

    private func sampleValues(_ touch: UITouch) -> TouchValues {
        let maxForce = touch.maximumPossibleForce
        let force = maxForce > 0 ? min(touch.force / maxForce, 1) : 0.5
        return TouchValues(force: force, altitude: touch.altitudeAngle, azimuth: touch.azimuthAngle(in: self))
    }

    /// `preciseLocation` is in this view's coordinate space; strokes are stored in canvas space.
    private func makePoint(_ touch: UITouch, predicted: Bool) -> StrokePoint {
        let viewLocation = touch.preciseLocation(in: self)
        let canvasLocation = inputTransform.toCanvas(viewLocation)
        let location = rulerSnap?.guide.project(canvasLocation) ?? canvasLocation // along the ruler's edge
        if touch.type != .pencil {
            return fingerPoint(touch, viewLocation: viewLocation, canvasLocation: location, predicted: predicted)
        }
        let v = sampleValues(touch)
        return StrokePoint(location: location, force: v.force, altitude: v.altitude, azimuth: v.azimuth,
                           timestamp: touch.timestamp)
    }

    private func endStroke(commit: Bool) {
        activeTouch = nil
        // Edits made by a stroke carried across pages share its group, for undo.
        document.editGroup = strokeGroup
        let joined = joinedStroke
        defer {
            document.editGroup = nil
            strokeGroup = nil
            joinedStroke = false
        }
        stopHoldWatch()
        if lassoPending || lassoSession != nil {
            finishLasso(commit: commit)
        }
        if shapeSnap != nil {
            finishShapeSnap(commit: commit)
        }
        finishToolGestures(commit: commit)
        endRulerSnap()
        var erased = eraseSession != nil && commit
        finishErasing()
        if let live {
            self.live = nil
            if live.stroke.brush.erases {
                setCursor(nil)
                erased = commit
            }
            // A scratch-out erases the ink under it, and the scratch itself is dropped like a cancelled stroke.
            // A piece joined from another page is only kept if it reached this one; it's never a tap or a shape.
            if commit, !live.stroke.points.isEmpty, joined ? !isOffPage(live) : !tapObjectIfTapped(live) && !convertToShape(live),
               !scratchOut(with: live) {
                if let (segment, dirty) = live.finish() { // the end taper, now the end is known
                    liveView.geometryChanged(of: live, fromSegment: segment, canvasRect: dirty)
                    zoomPanel?.liveView.geometryChanged(of: live, fromSegment: segment, canvasRect: dirty)
                    invalidateLive(canvasRect: dirty)
                }
                let geom = live.geometry()
                geometryCache[live.stroke.id] = geom
                let splits = live.stroke.brush.erases
                    ? splits(cutBy: live.stroke, hulls: live.allHulls) : []
                let revisionBefore = document.revision
                editDocument { document.add(live.stroke, splits: splits) }
                let deadline = CACurrentMediaTime() + 0.25
                pending.append(PendingStroke(live: live, geometry: geom, deadline: deadline,
                                             revisionBefore: revisionBefore, revisionAfter: document.revision))
                schedulePendingCommit()
                if !live.stroke.brush.erases {
                    controller?.inkDidCommit(on: document, bounds: geom.bounds)
                }
                if zoomPanel != nil {
                    zoomHeld.append(live)
                    followWriting(geom.bounds, of: live.stroke)
                    scheduleZoomRender()
                }
            } else {
                invalidateAllLive() // clears the live layer
            }
        }
        hud.state = .idle
        hud.predictedCount = 0
        publishHUD(force: true)
        // An erase carried across pages ends once, when its last piece does (`endWritingAcrossPages`).
        if erased, !isInkingOnAnyPage {
            controller?.eraserStrokeDidEnd()
        }
    }

    // MARK: - HUD

    private func updateFingerState(_ event: UIEvent?, ending: Set<UITouch> = []) {
        guard activeTouch == nil else { return }
        let fingers = event?.allTouches?.filter {
            isFinger($0) && !ending.contains($0) && $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        hud.state = fingers > 0 ? .finger(fingers) : (hoverActive ? .hovering : .idle)
        publishHUD(force: true)
    }

    private func publishHUD(force: Bool) {
        guard let telemetry, controller?.hudVisible == true else { return }
        let now = ProcessInfo.processInfo.systemUptime // same clock as UITouch.timestamp
        hud.samplesPerSecond = sampleRate.rate(at: now)
        hud.eventsPerSecond = eventRate.rate(at: now)
        hud.pendingEstimates = pendingEstimates.count
        hud.strokeCount = document.strokes.count
        telemetry.submit(hud, immediately: force)
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

    private func gestureBegan() {
        finishSettling()
        if activeGestureCount == 0, !didTransformInTouchSequence {
            gestureStartTransform = viewTransform
        }
        activeGestureCount += 1
    }

    private func gestureEnded() {
        activeGestureCount = max(0, activeGestureCount - 1)
        guard !isCancellingGesture else { return }
        if activeGestureCount == 0 {
            liveView.settle(at: viewTransform)
        }
        if activeGestureCount == 0, bitmapTransform != viewTransform || displayedTransform != viewTransform {
            requestFullRender()
        }
    }

    private func transformDidChange() {
        didTransformInTouchSequence = true
        updateCommittedLayerTransform()
        updatePageChrome()
        liveView.follow(viewTransform)
        updateLassoOverlay()
        requestFullRender()
        controller?.zoomDidChange(viewTransform.scale)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if g.state == .began {
                gestureBegan()
                panTranslation = .zero
            }
            let t = g.translation(in: self)
            viewTransform.offset.x += t.x
            viewTransform.offset.y += t.y
            panTranslation.x += t.x
            panTranslation.y += t.y
            g.setTranslation(.zero, in: self)
            transformDidChange()
        case .ended:
            gestureEnded()
            if !turnPageIfSwiped(velocity: g.velocity(in: self)) {
                settleIfFitted()
            }
        case .cancelled, .failed:
            gestureEnded()
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if g.state == .began {
                gestureBegan()
            }
            let focus = g.location(in: self)
            let fitted = fittedTransform()
            let range = ViewTransform.zoomRange(fitScale: fitted.scale)
            let newScale = min(max(viewTransform.scale * g.scale, range.lowerBound), range.upperBound)
            let oldScale = viewTransform.scale
            if abs(g.scale - 1) > 0.01 {
                didPinchInSequence = true
            }
            let k = newScale / oldScale
            // Zoom about the pinch centroid: keep the canvas point under it fixed.
            viewTransform.offset = CGPoint(x: focus.x - (focus.x - viewTransform.offset.x) * k,
                                           y: focus.y - (focus.y - viewTransform.offset.y) * k)
            viewTransform.scale = newScale
            // Near the zoom-out limit, ease the page back to the centre so it lands exactly on the fitted
            // view rather than stopping wherever the pinch left it.
            let pull = ViewTransform.recentringAmount(from: oldScale, to: newScale, fitScale: fitted.scale)
            if pull > 0 {
                viewTransform.offset = CGPoint(x: viewTransform.offset.x + (fitted.offset.x - viewTransform.offset.x) * pull,
                                               y: viewTransform.offset.y + (fitted.offset.y - viewTransform.offset.y) * pull)
            }
            g.scale = 1
            transformDidChange()
        case .ended, .cancelled, .failed:
            gestureEnded()
        default:
            break
        }
    }

    /// Turns the page after a sideways swipe, but only while the whole page is in view: zoomed in, a pan
    /// scrolls around the page instead. Pinches and three-finger swipes (undo/redo) never turn the page.
    /// Returns whether the swipe was handed on to turn the page.
    private func turnPageIfSwiped(velocity: CGPoint) -> Bool {
        guard maxDirectTouchesInSequence <= 2, !didPinchInSequence, isAtFittedZoom,
              let swipe = PageSwipe.detect(translation: panTranslation, velocity: velocity, viewWidth: bounds.width),
              let controller, controller.canSwipe(swipe)
        else { return false }
        controller.swipeToPage(swipe)
        return true
    }

    private var isAtFittedZoom: Bool {
        viewTransform.scale <= fittedTransform().scale * 1.02
    }

    /// While the whole page is in view there's nothing to pan to, so a drag that didn't turn the page
    /// (too short, or past the first or last page) slides the page back to the centre.
    private func settleIfFitted() {
        guard isAtFittedZoom, activeGestureCount == 0 else { return }
        let target = fittedTransform()
        guard target != viewTransform else { return }
        settleLink?.invalidate()
        settleFrom = viewTransform
        settleTo = target
        settleStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepSettling(_:)))
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    @objc private func stepSettling(_: CADisplayLink) {
        let t = min((CACurrentMediaTime() - settleStart) / 0.25, 1)
        let e = 1 - pow(1 - t, 3) // ease out
        viewTransform = ViewTransform(
            scale: settleFrom.scale + (settleTo.scale - settleFrom.scale) * e,
            offset: CGPoint(x: settleFrom.offset.x + (settleTo.offset.x - settleFrom.offset.x) * e,
                            y: settleFrom.offset.y + (settleTo.offset.y - settleFrom.offset.y) * e)
        )
        updateCommittedLayerTransform()
        updatePageChrome()
        liveView.follow(viewTransform)
        updateLassoOverlay()
        if t >= 1 {
            finishSettling()
        }
    }

    /// Jumps to the end of the slide back, if one is running.
    private func finishSettling() {
        guard let link = settleLink else { return }
        link.invalidate()
        settleLink = nil
        viewTransform = settleTo
        updateCommittedLayerTransform()
        updatePageChrome()
        liveView.settle(at: viewTransform)
        updateLassoOverlay()
        requestFullRender()
        controller?.zoomDidChange(viewTransform.scale)
    }

    /// Cancels any incidental pan/pinch from multi-finger taps or swipes and restores `gestureStartTransform`.
    /// Returns true if the transform was reverted and needs a full render when undo/redo is a no-op.
    private func cancelIncidentalPanZoom() -> Bool {
        guard activeGestureCount > 0 || didTransformInTouchSequence else { return false }
        isCancellingGesture = true
        for r in [pan, pinch] as [UIGestureRecognizer] {
            r.isEnabled = false
            r.isEnabled = true
        }
        isCancellingGesture = false
        activeGestureCount = 0
        didTransformInTouchSequence = false
        viewTransform = gestureStartTransform
        generation &+= 1
        updateCommittedLayerTransform()
        updatePageChrome()
        liveView.settle(at: viewTransform)
        controller?.zoomDidChange(viewTransform.scale)
        return bitmapTransform != viewTransform || displayedTransform != viewTransform
    }

    @objc private func handleSwipe(_ g: UISwipeGestureRecognizer) {
        let needsRender = cancelIncidentalPanZoom()
        let changed = g.direction == .left ? undo() : redo()
        if needsRender, !changed {
            requestFullRender()
        }
    }

    @objc private func handleTwoFingerTap(_ g: MultiFingerTapRecognizer) {
        guard g.state == .ended else { return }
        let needsRender = cancelIncidentalPanZoom()
        if !undo(), needsRender {
            requestFullRender()
        }
    }

    @objc private func handleThreeFingerTap(_ g: MultiFingerTapRecognizer) {
        guard g.state == .ended else { return }
        let needsRender = cancelIncidentalPanZoom()
        if !redo(), needsRender {
            requestFullRender()
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
            palmRejector.pencilSeen(at: location, time: ProcessInfo.processInfo.systemUptime)
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

// MARK: - Palm rejection and finger ink

extension CanvasView {
    /// Whether a finger draws ink, from the Pencil settings and the system's Only Draw with Apple Pencil.
    var fingerDraws: Bool {
        (controller?.pencilSettings.fingerDrawing ?? .system)
            .fingerDraws(pencilOnlySystemSetting: UIPencilInteraction.prefersPencilOnlyDrawing)
    }

    /// A direct touch that isn't a resting palm.
    private func isFinger(_ touch: UITouch) -> Bool {
        touch.type == .direct && !isPalm(touch)
    }

    /// Classifies a direct touch when it's first seen (by a gesture recognizer or `touchesBegan`) and
    /// again as its contact grows: once a palm, it stays one until it lifts.
    private func isPalm(_ touch: UITouch) -> Bool {
        guard touch.type == .direct else { return false }
        if palmTouches.contains(touch) {
            return true
        }
        if palmRejector.rejects(location: touch.location(in: self), radius: touch.majorRadius,
                                time: touch.timestamp) {
            palmTouches.insert(touch)
            return true
        }
        return false
    }

    /// Re-reads the settings the canvas caches: palm rejection and how many fingers pan.
    func pencilSettingsDidChange() {
        if let settings = controller?.pencilSettings {
            palmRejector.sensitivity = settings.palmRejection
            palmRejector.handedness = settings.handedness
        }
        pan.minimumNumberOfTouches = fingerDraws ? 2 : 1 // one finger draws, so two pan
    }

    /// Finger ink (and the simulator's stand-in Pencil) has no pressure, so it's faked from drag speed:
    /// slow = heavy, fast = light, low-passed so the width changes smoothly.
    private func fingerPoint(_ touch: UITouch, viewLocation: CGPoint, canvasLocation: CGPoint,
                             predicted: Bool) -> StrokePoint {
        var force: CGFloat = 0.6
        if let prev = fingerPrevious {
            force = prev.force
            let dt = touch.timestamp - prev.time
            if dt > 0 {
                let speed = viewLocation.distance(to: prev.location) / CGFloat(dt) // points per second
                let target = min(max(1 - speed / 2200, 0.1), 1)
                force = prev.force + (target - prev.force) * 0.2
            }
        }
        if !predicted {
            fingerPrevious = FingerSample(location: viewLocation, time: touch.timestamp, force: force)
        }
        #if targetEnvironment(simulator)
            let altitude = controller?.simulatedAltitude ?? .pi / 2
        #else
            let altitude = CGFloat.pi / 2
        #endif
        return StrokePoint(location: canvasLocation, force: force, altitude: altitude,
                           azimuth: -.pi / 4, timestamp: touch.timestamp)
    }
}
