import UIKit

// MARK: - Lasso, selection and the object layer

/// Selecting strokes and objects with the lasso (a loop, a rectangle or a tap) and transforming them with the
/// selection box's handles. The geometry is in `SelectionGeometry`; the document records the edits.
extension CanvasView {
    /// Selection handles, in view points: how far from a knob a touch still grabs it, how far the rotate
    /// knob sits above the box, and how big the knobs are drawn.
    static let handleReach: CGFloat = 22
    static let rotateHandleDistance: CGFloat = 28
    static let handleRadius: CGFloat = 6
    /// A lasso gesture that stays within this many view points is a tap: it selects the topmost stroke or
    /// object under it.
    static let tapSlop: CGFloat = 8

    func invalidateMoved() {
        let ids = document.lastReshapedIDs
        guard !ids.isEmpty else { return }
        for id in ids {
            coordinator.forgetGeometry(id)
        }
        // Moved strokes may still be waiting in `pending` with stale geometry; the full render redraws them.
        coordinator.dropPending(ids)
        if !selection.isEmpty {
            updateSelectionBox()
        }
    }

    /// Fits a fresh box around the selection (see `SelectionGeometry.box`) and tells the controller.
    func updateSelectionBox() {
        let strokeBounds = document.strokes.filter { selection.strokeIDs.contains($0.id) }.map { coordinator.bounds(of: $0) }
        let objects = document.objects.filter { selection.objectIDs.contains($0.id) }
        selectionBox = SelectionGeometry.box(strokeBounds: strokeBounds, objects: objects)
        // Only armed while there's something to drag out, so its long press never touches the ink path.
        selectionDragInteraction.isEnabled = selectionBox != nil
        if isActiveCanvas {
            controller?.selectionDidChange(!selection.isEmpty)
            controller?.selectedShapesDidChange(selectedShapeStyle)
        }
        updateLassoOverlay()
    }

    func select(_ newSelection: PageSelection) {
        selection = newSelection
        if newSelection.isEmpty {
            dismissEditMenu()
        }
        updateSelectionBox()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        select(.empty)
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let deleted = selection
        for id in deleted.strokeIDs {
            coordinator.forgetGeometry(id)
        }
        editDocument { document.delete(deleted) }
        select(.empty)
        dropOrphanedPendingStrokes()
        refreshObjects()
        if !deleted.strokeIDs.isEmpty {
            coordinator.invalidateAll()
        }
    }

    /// Adds a placeholder object (the object layer's test object) in the middle of the visible part of
    /// the page and selects it, so it can be moved, resized and rotated straight away.
    func insertPlaceholderObject(color: PenColor) {
        let page = document.pageBounds
        var visible = viewTransform.toCanvas(bounds).intersection(page)
        if visible.isNull || visible.isEmpty {
            visible = page
        }
        let width = min(visible.width * 0.4, 220), height = width * 0.65
        let frame = CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        let object = PlaceholderObject(frame: frame, color: color)
        editDocument { document.addObject(object) }
        refreshObjects()
        select(PageSelection(objectIDs: [object.id]))
    }

    /// Every visible stroke as selection sees it, limited to those that may reach `region` (canvas space),
    /// bottom first: the page's index finds them without looking at the rest.
    func strokeShapes(near region: CGRect) -> [SelectionGeometry.StrokeShape] {
        document.strokes(in: region).compactMap { stroke in
            // Pixel-eraser strokes are invisible, so they're never selectable.
            guard !stroke.brush.erases else { return nil }
            let path = stroke.points.map(\.location)
            let radius = stroke.brush.maxWidth / 2
            let bounds = coordinator.geometry.cachedBounds(stroke.id)
                ?? LassoGeometry.bounds(of: path).insetBy(dx: -radius, dy: -radius)
            guard bounds.intersects(region) else { return nil }
            return SelectionGeometry.StrokeShape(id: stroke.id, path: path, bounds: bounds, radius: radius)
        }
    }

    /// The strokes the lasso may pick up near `region`: none when its filter leaves ink out.
    func filteredStrokeShapes(near region: CGRect) -> [SelectionGeometry.StrokeShape] {
        (controller?.lassoFilter ?? .all).contains(.ink) ? strokeShapes(near: region) : []
    }

    /// The objects the lasso may pick up: none when its filter leaves objects out. With `region`, only
    /// those whose bounds reach it (a lasso picks up nothing beyond its own bounds).
    func filteredObjects(near region: CGRect? = nil) -> [any PageObject] {
        guard (controller?.lassoFilter ?? .all).contains(.objects) else { return [] }
        return region.map(document.objects(in:)) ?? document.objects
    }

    func handleLassoSample(_ p: CGPoint) {
        guard let controller else { return }
        switch lassoSession {
        case nil:
            if beginShapeReshape(at: p) {
                // A selected shape's own handle: drag it to reshape the shape.
                lassoPending = false
                return
            }
            if let box = selectionBox, !selection.isEmpty, let handle = selectionHandle(at: p, box: box) {
                // Dragging the selection or a handle transforms it. Pending strokes are redrawn by the full render.
                coordinator.dropPending(selection.strokeIDs)
                lassoSession = .transforming(SelectionDrag(handle: handle, start: p, box: box,
                                                           session: document.beginTransform(selection)))
            } else {
                lassoHadSelection = !selection.isEmpty
                clearSelection()
                lassoSession = .drawing([p])
            }
            dismissEditMenu()
            lassoPending = false
        case var .drawing(pts)?:
            switch controller.lassoMode {
            case .freeform:
                if let last = pts.last, last.distance(to: p) * inputTransform.scale < 1.5 {
                    return
                }
                pts.append(p)
            case .square:
                pts = [pts[0], p]
            }
            lassoSession = .drawing(pts)
            updateLassoOverlay()
        case var .transforming(drag)?:
            let t = SelectionGeometry.transform(for: drag.handle, box: drag.box, from: drag.start, to: p,
                                                minimumSize: 8 / viewTransform.scale,
                                                keepsAspectRatio: drag.session.objects.contains { $0 is ImageObject })
            guard t != drag.transform else { return }
            drag.transform = t
            lassoSession = .transforming(drag)
            preview(drag)
        case let .reshaping(reshape)?:
            updateShapeReshape(reshape, to: p)
        }
    }

    /// Shows the drag's strokes and objects where it has put them.
    func preview(_ drag: SelectionDrag) {
        for stroke in drag.session.strokes {
            coordinator.forgetGeometry(stroke.id)
        }
        document.previewTransform(drag.session, by: drag.transform)
        if !drag.session.strokes.isEmpty {
            coordinator.invalidateAll()
        }
        if !drag.session.objects.isEmpty {
            refreshObjects()
        }
        updateLassoOverlay()
    }

    func finishLasso(commit: Bool) {
        let session = lassoSession
        lassoSession = nil
        lassoPending = false
        defer { updateLassoOverlay() }
        switch session {
        case let .drawing(pts)?:
            guard commit, let controller, let first = pts.first else { return }
            let extent = LassoGeometry.bounds(of: pts)
            if max(extent.width, extent.height) * inputTransform.scale <= Self.tapSlop {
                // A tap: the topmost stroke or object under it.
                let tolerance = Self.tapSlop / inputTransform.scale
                let near = CGRect(origin: first, size: .zero).insetBy(dx: -tolerance, dy: -tolerance)
                let hit = SelectionGeometry.hitTest(first, tolerance: tolerance, strokes: filteredStrokeShapes(near: near),
                                                    objects: filteredObjects())
                select(hit ?? .empty)
                if hit != nil {
                    showSelectionMenu()
                } else if !lassoHadSelection, controller.canPaste {
                    showPasteMenu(at: first)
                }
                return
            }
            guard let polygon = LassoGeometry.region(mode: controller.lassoMode, points: pts) else { return }
            // Whole strokes and objects are selected even if only part of them is inside the region.
            let region = LassoGeometry.bounds(of: polygon)
            select(SelectionGeometry.select(in: polygon, strokes: filteredStrokeShapes(near: region),
                                            objects: filteredObjects(near: region)))
            showSelectionMenu()
        case let .transforming(drag)?:
            if commit {
                editDocument { document.commitTransform(drag.session, by: drag.transform) }
                refreshObjects() // the objects go back into their tiles, where they were put
                // The box turns and stretches with what it holds.
                selectionBox = drag.box.applying(drag.transform)
                showSelectionMenu()
            } else {
                document.cancelTransform(drag.session)
                for stroke in drag.session.strokes {
                    coordinator.forgetGeometry(stroke.id)
                }
                if !drag.session.strokes.isEmpty {
                    coordinator.invalidateAll()
                }
                refreshObjects()
                selectionBox = drag.box
            }
        case let .reshaping(reshape)?:
            finishShapeReshape(reshape, commit: commit)
        case nil:
            break
        }
    }

    /// The selection box, dashed, with a knob at each corner for resizing and one above it for rotating.
    /// A single selected shape also shows its own handles; a line or arrow shows only those.
    func drawSelection(_ box: SelectionBox, accent: UIColor, in ctx: CGContext) {
        let shape = selectedShape
        if let shape, shape.shape.isLinear {
            drawShapeHandles(shape, accent: accent, in: ctx)
            return
        }
        let corners = box.corners.map { viewTransform.toView($0) }
        let outline = CGMutablePath()
        outline.addLines(between: corners)
        outline.closeSubpath()
        ctx.addPath(outline)
        ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
        ctx.fillPath()
        ctx.addPath(outline)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        let top = viewTransform.toView(CGPoint(x: box.rect.midX, y: box.rect.minY).applying(box.transform))
        let knob = viewTransform.toView(SelectionGeometry.rotateHandle(
            of: box, distance: Self.rotateHandleDistance / viewTransform.scale
        ))
        ctx.move(to: top)
        ctx.addLine(to: knob)
        ctx.setLineWidth(1)
        ctx.strokePath()
        let r = Self.handleRadius
        ctx.setFillColor(paperColor.resolvedColor(with: InkTheme.onPaper).cgColor)
        ctx.setLineWidth(1.5)
        for point in corners + [knob] {
            let circle = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
            ctx.fillEllipse(in: circle)
            ctx.strokeEllipse(in: circle)
        }
        if let shape, !shape.handles.isEmpty {
            drawShapeHandles(shape, accent: accent, in: ctx) // over the box's outline
        }
    }
}
