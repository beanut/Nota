import UIKit

/// The zoom window: a box on the page and a writing panel at the bottom of the canvas that magnifies it.
///
/// Touches that begin in the panel's ink area are mapped through the panel's transform instead of the
/// page's, so ink written large in the panel lands small inside the box, and every tool works there as it
/// does on the page. When a stroke written in the panel reaches the box's advance zone the box moves along
/// the line, and at the end of the line on to the next (`ZoomWindow`).
///
/// The panel shows the box's ink the way the canvas shows the page's: a committed image, rendered off the
/// main thread whenever the page's committed bitmap changes, under a live layer for the stroke being written.
extension CanvasView {
    /// Space between the panel and the page above it, and the panel's inset from the sides.
    static let zoomPanelGap: CGFloat = 16

    /// The panel's frame: full width above the page bar, a fifth of the view tall (160–260 pt).
    func zoomPanelFrame() -> CGRect {
        let s = safeAreaInsets, m = controller?.pageMargins ?? CanvasController.defaultPageMargins
        let height = min(max(bounds.height * 0.2, 160), 260)
        // The page bar floats in the bottom margin; the panel sits just above it.
        let bottom = bounds.maxY - s.bottom - max(m.bottom - Self.zoomPanelGap, 0)
        let gap = Self.zoomPanelGap
        return CGRect(x: s.left + gap, y: bottom - height,
                      width: max(bounds.width - s.left - s.right - 2 * gap, 1), height: height)
    }

    /// The panel's ink area, in this view's coordinates.
    var zoomInkFrameInView: CGRect {
        guard let panel = zoomPanel else { return .null }
        return panel.inkFrame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Page → this view through the panel: where a page point shows in the panel.
    var zoomInputTransform: ViewTransform {
        guard let panel = zoomPanel else { return viewTransform }
        var t = panel.inkTransform
        let origin = zoomInkFrameInView.origin
        t.offset = CGPoint(x: t.offset.x + origin.x, y: t.offset.y + origin.y)
        return t
    }

    // MARK: Showing and hiding

    /// Shows or hides the panel and box to match the controller, and refits the page around the panel.
    func zoomWindowVisibilityDidChange() {
        let visible = controller?.zoomWindowVisible ?? false
        if visible, zoomPanel == nil {
            let theme = controller?.theme ?? .standard
            let box = ZoomBoxOverlayView()
            box.apply(theme, traits: traitCollection)
            addSubview(box)
            zoomBoxView = box
            let panel = ZoomPanelView()
            panel.apply(theme, traits: traitCollection)
            panel.liveView.entries = { [weak self] in self?.zoomLiveEntries() ?? [] }
            addSubview(panel)
            zoomPanel = panel
        } else if !visible, let panel = zoomPanel {
            panel.removeFromSuperview()
            zoomBoxView?.removeFromSuperview()
            zoomPanel = nil
            zoomBoxView = nil
            zoomWindow = nil
            zoomHeld.removeAll()
            zoomTouch = nil
            zoomDrag = nil
            zoomGeneration &+= 1
            zoomRenderQueue.async { [weak self] in self?.zoomBitmap = nil }
            controller?.zoomWindowDidChange(controlsFrame: nil, canGoBack: false)
        }
        pageMarginsDidChange()
    }

    /// Places the panel for the current bounds and safe area.
    func layoutZoomPanel() {
        guard let panel = zoomPanel else { return }
        let frame = zoomPanelFrame()
        if panel.frame != frame {
            panel.frame = frame
            panel.layoutIfNeeded()
        }
    }

    /// Rebuilds the box for the page, its lines and the panel's shape, keeping its place if it has one.
    func updateZoomWindow() {
        guard let panel = zoomPanel, panel.inkFrame.width > 1 else { return }
        let lines = controller?.writingLines?(document) ?? .lines(for: document.template, on: document.pageSize)
        let window = ZoomWindow(page: document.pageBounds, lines: lines,
                                aspect: panel.inkFrame.width / panel.inkFrame.height,
                                box: zoomWindow?.box ?? controller?.zoomBox)
        if window != zoomWindow || panel.inkTransform == ViewTransform() {
            setZoomWindow(window)
        } else {
            controller?.zoomWindowDidChange(controlsFrame: convert(panel.controlsFrame, from: panel),
                                            canGoBack: window.canGoBack)
        }
    }

    private func setZoomWindow(_ window: ZoomWindow) {
        zoomWindow = window
        controller?.zoomBox = window.box
        guard let panel = zoomPanel else { return }
        let scale = panel.inkFrame.width / window.box.width
        let transform = ViewTransform(scale: scale,
                                      offset: CGPoint(x: -window.box.minX * scale, y: -window.box.minY * scale))
        let moved = transform != panel.inkTransform
        panel.show(window, at: transform)
        if moved {
            panel.liveView.settle(at: transform)
        }
        updatePageChrome()
        controller?.zoomWindowDidChange(controlsFrame: convert(panel.controlsFrame, from: panel),
                                        canGoBack: window.canGoBack)
        scheduleZoomRender()
    }

    // MARK: Moving the box

    /// The panel's buttons: back along the line, on along it, or to the start of the next line.
    func moveZoomWindow(_ move: ZoomMove) {
        guard var window = zoomWindow, activeTouch == nil else { return }
        switch move {
        case .back: window.back()
        case .advance: window.advance()
        case .newLine: window.newLine()
        }
        setZoomWindow(window)
    }

    /// A stroke just ended. If it was written in the panel and reached the advance zone, the box moves on.
    func followWriting(_ bounds: CGRect, of stroke: Stroke) {
        guard inputInZoomPanel, stroke.tool != .pixelEraser, var window = zoomWindow,
              window.strokeEnded(bounds: bounds) != .stayed else { return }
        setZoomWindow(window)
    }

    /// Starts dragging or resizing the box if `touch` landed on one of its handles.
    func beginZoomDrag(_ touch: UITouch) -> Bool {
        guard zoomTouch == nil, let window = zoomWindow else { return false }
        let location = touch.location(in: self)
        guard let handle = ZoomBoxOverlayView.handle(at: location, box: viewTransform.toView(window.box))
        else { return false }
        zoomTouch = touch
        zoomDrag = ZoomDrag(handle: handle, start: location, box: window.box)
        return true
    }

    func updateZoomDrag(_ touch: UITouch) {
        guard let drag = zoomDrag, var window = zoomWindow else { return }
        let location = touch.location(in: self)
        let dx = (location.x - drag.start.x) / viewTransform.scale
        let dy = (location.y - drag.start.y) / viewTransform.scale
        switch drag.handle {
        case .move: window.move(to: CGPoint(x: drag.box.minX + dx, y: drag.box.minY + dy))
        case .resize: window.resize(toWidth: drag.box.width + dx)
        }
        setZoomWindow(window)
    }

    func endZoomDrag() {
        if var window = zoomWindow, zoomDrag?.handle == .move {
            window.snapToLine()
            setZoomWindow(window)
        }
        zoomTouch = nil
        zoomDrag = nil
    }

    // MARK: Rendering the panel

    /// What the panel's live layer shows: strokes its committed image doesn't have yet, then the one being
    /// written.
    private func zoomLiveEntries() -> [LiveInkView.Entry] {
        (zoomHeld + (live.map { [$0] } ?? [])).map {
            LiveInkView.Entry(stroke: $0, previewFill: $0.stroke.tool == .pixelEraser ? paperColor.cgColor : nil)
        }
    }

    /// Renders the box's ink into the panel soon, once per run-loop turn and one render at a time.
    func scheduleZoomRender() {
        guard zoomPanel != nil else { return }
        if zoomRenderInFlight {
            zoomRenderRequested = true
            return
        }
        guard !zoomRenderScheduled else { return }
        zoomRenderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            zoomRenderScheduled = false
            renderZoomPanel()
        }
    }

    private func renderZoomPanel() {
        guard let panel = zoomPanel, zoomWindow != nil else { return }
        zoomGeneration &+= 1
        zoomRenderInFlight = true
        let generation = zoomGeneration
        let transform = panel.inkTransform
        let bounds = CGRect(origin: .zero, size: panel.inkFrame.size)
        let scale = bitmapScale
        let pixels = CGSize(width: (bounds.width * scale).rounded(.up), height: (bounds.height * scale).rounded(.up))
        let visible = transform.toCanvas(bounds).insetBy(dx: -4, dy: -4)
        // Only the strokes that reach the box. Geometry not cached yet is culled by its points.
        let items: [CommittedRenderer.Item] = document.strokes.compactMap { stroke in
            if let geometry = geometryCache[stroke.id] {
                guard geometry.bounds.intersects(visible) else { return nil }
                return CommittedRenderer.Item(id: stroke.id, kind: stroke.tool, color: stroke.color,
                                              geometry: geometry, stroke: nil)
            }
            guard Self.roughBounds(of: stroke).intersects(visible) else { return nil }
            return CommittedRenderer.Item(id: stroke.id, kind: stroke.tool, color: stroke.color,
                                          geometry: nil, stroke: stroke)
        }
        let included = Set(zoomHeld.map { ObjectIdentifier($0) })

        zoomRenderQueue.async { [weak self] in
            guard let self else { return }
            if zoomBitmap.map({ CGSize(width: $0.width, height: $0.height) }) != pixels {
                zoomBitmap = CommittedRenderer.makeBitmap(pixelSize: pixels, scale: scale)
            }
            var image: CGImage?
            if let ctx = zoomBitmap {
                CommittedRenderer.render(items, into: ctx, bounds: bounds, transform: transform)
                image = ctx.makeImage()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                zoomRenderInFlight = false
                if generation == zoomGeneration, let panel = zoomPanel {
                    panel.publish(image, transform: transform)
                    if !included.isEmpty {
                        zoomHeld.removeAll { included.contains(ObjectIdentifier($0)) }
                        panel.liveView.invalidateAll()
                    }
                }
                if zoomRenderRequested {
                    zoomRenderRequested = false
                    scheduleZoomRender()
                }
            }
        }
    }

    /// A stroke's points' bounds grown by its widest nib: never smaller than its ink.
    private static func roughBounds(of stroke: Stroke) -> CGRect {
        guard let first = stroke.points.first?.location else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in stroke.points {
            minX = min(minX, point.location.x)
            maxX = max(maxX, point.location.x)
            minY = min(minY, point.location.y)
            maxY = max(maxY, point.location.y)
        }
        let r = stroke.style.width * 2
        return CGRect(x: minX - r, y: minY - r, width: maxX - minX + 2 * r, height: maxY - minY + 2 * r)
    }

    // MARK: Cursor

    /// Shows the hover or eraser cursor, `path` in this view's coordinates. In the zoom panel it's drawn
    /// on the panel's live layer instead of the page's.
    func setCursor(_ path: CGPath?, inZoomPanel: Bool = false) {
        if inZoomPanel, let panel = zoomPanel {
            let origin = zoomInkFrameInView.origin
            var shift = CGAffineTransform(translationX: -origin.x, y: -origin.y)
            panel.liveView.setCursor(path.flatMap { $0.copy(using: &shift) })
            liveView.setCursor(nil)
        } else {
            liveView.setCursor(path)
            zoomPanel?.liveView.setCursor(nil)
        }
    }

    /// The nib's outline at `canvasPoint`, drawn through `transform` (canvas → this view): its size and
    /// tilt, plus a tick from the centre showing the barrel's roll when the Pencil reports one (Pencil Pro).
    func tipOutline(at canvasPoint: CGPoint, altitude: CGFloat, azimuth: CGFloat, roll: CGFloat = 0,
                    transform: ViewTransform) -> CGPath? {
        guard let path = nibOutline(at: canvasPoint, altitude: altitude, azimuth: azimuth, transform: transform)
        else { return nil }
        guard roll != 0, let controller, controller.tool != .eraser else { return path }
        let c = transform.toView(canvasPoint)
        let reach = max(path.boundingBoxOfPath.width, path.boundingBoxOfPath.height) / 2 + 5
        let mutable = CGMutablePath()
        mutable.addPath(path)
        mutable.move(to: c)
        mutable.addLine(to: CGPoint(x: c.x + cos(roll) * reach, y: c.y + sin(roll) * reach))
        return mutable
    }

    private func nibOutline(at canvasPoint: CGPoint, altitude: CGFloat, azimuth: CGFloat,
                            transform: ViewTransform) -> CGPath? {
        guard let controller, controller.tool != .lasso else { return nil }
        let path = CGMutablePath()
        if controller.tool == .eraser {
            let r = CGFloat(controller.current.width) / 2
            let c = transform.toView(canvasPoint)
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        } else {
            let style = controller.strokeTemplate(viewScale: transform.scale).style
            let sample = StrokePoint(location: canvasPoint, force: 1, altitude: altitude, azimuth: azimuth, timestamp: 0)
            let poly = StrokeRenderer.polygon(for: StrokeRenderer.tip(for: sample, style: style))
            path.addLines(between: poly, transform: transform.affine)
            path.closeSubpath()
        }
        return path
    }
}

/// A touch dragging the zoom box by its tab or resizing it by its knob, and where it started.
struct ZoomDrag {
    let handle: ZoomBoxOverlayView.Handle
    let start: CGPoint
    let box: CGRect
}
