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
            forgetGeometry(id)
        }
        // Moved strokes may still be waiting in `pending` with stale geometry; the full render redraws them.
        dropPending(ids)
        if !selection.isEmpty {
            updateSelectionBox()
        }
    }

    /// Fits a fresh box around the selection (see `SelectionGeometry.box`) and tells the controller.
    func updateSelectionBox() {
        let strokeBounds = document.strokes.filter { selection.strokeIDs.contains($0.id) }.map { geometry(for: $0).bounds }
        let objects = document.objects.filter { selection.objectIDs.contains($0.id) }
        selectionBox = SelectionGeometry.box(strokeBounds: strokeBounds, objects: objects)
        controller?.selectionDidChange(!selection.isEmpty)
        updateLassoOverlay()
    }

    func select(_ newSelection: PageSelection) {
        selection = newSelection
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
            forgetGeometry(id)
        }
        editDocument { document.delete(deleted) }
        select(.empty)
        dropOrphanedPendingStrokes()
        refreshObjects()
        if !deleted.strokeIDs.isEmpty {
            requestFullRender()
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

    /// Every visible stroke as selection sees it, limited to those that may reach `region` (canvas space).
    func strokeShapes(near region: CGRect) -> [SelectionGeometry.StrokeShape] {
        document.strokes.compactMap { stroke in
            // Pixel-eraser strokes are invisible, so they're never selectable.
            guard !stroke.brush.erases else { return nil }
            let path = stroke.points.map(\.location)
            let radius = stroke.brush.maxWidth / 2
            let bounds = geometryCache[stroke.id]?.bounds
                ?? LassoGeometry.bounds(of: path).insetBy(dx: -radius, dy: -radius)
            guard bounds.intersects(region) else { return nil }
            return SelectionGeometry.StrokeShape(id: stroke.id, path: path, bounds: bounds, radius: radius)
        }
    }

    func handleLassoSample(_ p: CGPoint) {
        guard let controller else { return }
        switch lassoSession {
        case nil:
            if let box = selectionBox, !selection.isEmpty,
               let handle = SelectionGeometry.handle(at: p, box: box, reach: Self.handleReach / inputTransform.scale,
                                                     rotateDistance: Self.rotateHandleDistance / viewTransform.scale) {
                // Dragging the selection or a handle transforms it. Pending strokes are redrawn by the full render.
                dropPending(selection.strokeIDs)
                lassoSession = .transforming(SelectionDrag(handle: handle, start: p, box: box,
                                                           session: document.beginTransform(selection)))
            } else {
                clearSelection()
                lassoSession = .drawing([p])
            }
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
                                                minimumSize: 8 / viewTransform.scale)
            guard t != drag.transform else { return }
            drag.transform = t
            lassoSession = .transforming(drag)
            preview(drag)
        }
    }

    /// Shows the drag's strokes and objects where it has put them.
    func preview(_ drag: SelectionDrag) {
        for stroke in drag.session.strokes {
            forgetGeometry(stroke.id)
        }
        document.previewTransform(drag.session, by: drag.transform)
        if !drag.session.strokes.isEmpty {
            requestFullRender()
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
                let hit = SelectionGeometry.hitTest(first, tolerance: tolerance, strokes: strokeShapes(near: near),
                                                    objects: document.objects)
                select(hit ?? .empty)
                return
            }
            guard let polygon = LassoGeometry.region(mode: controller.lassoMode, points: pts) else { return }
            // Whole strokes and objects are selected even if only part of them is inside the region.
            select(SelectionGeometry.select(in: polygon, strokes: strokeShapes(near: LassoGeometry.bounds(of: polygon)),
                                            objects: document.objects))
        case let .transforming(drag)?:
            if commit {
                editDocument { document.commitTransform(drag.session, by: drag.transform) }
                // The box turns and stretches with what it holds.
                selectionBox = drag.box.applying(drag.transform)
            } else {
                document.cancelTransform(drag.session)
                for stroke in drag.session.strokes {
                    forgetGeometry(stroke.id)
                }
                if !drag.session.strokes.isEmpty {
                    requestFullRender()
                }
                refreshObjects()
                selectionBox = drag.box
            }
        case nil:
            break
        }
    }
}
