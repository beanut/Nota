import UIKit

/// A stroke that snapped to a shape while the Pencil is still down: the shape as recognised, where the
/// Pencil was held, and the shape as the Pencil has since sized it. Shown over the page's objects until
/// the Pencil lifts, when it's added to the page.
struct ShapeSnap {
    let original: ShapeObject
    let hold: CGPoint
    var shape: ShapeObject
    /// Whether the Pencil has moved off the hold point; until it does, the shape stays as recognised.
    var moved = false
}

/// Dragging one of a selected shape's handles: the shape as it was, which handle, and how far the
/// touch landed from the handle (so the handle doesn't jump to the touch).
struct ShapeReshape {
    let original: ShapeObject
    let handle: Int
    let offset: CGPoint
}

// MARK: - Shapes

/// The shape tool, hold-to-snap and reshaping shapes by their handles. Recognition is in
/// `ShapeRecognizer`; the document records the edits.
extension CanvasView {
    /// How close (view points) an end or corner has to come to another shape's anchor to snap to it.
    static let shapeSnapDistance: CGFloat = 12
    /// Strokes smaller than this (view points) aren't snapped on hold, so short handwriting stays ink.
    static let holdShapeMinimumSize: CGFloat = 30
    /// The shape tool ignores strokes smaller than this (view points): a tap.
    static let shapeToolMinimumSize: CGFloat = 8
    /// How far (radians) a line or arrow being drawn or reshaped may be from a multiple of 45° and still snap.
    static let shapeAngleSnap: CGFloat = 6 * .pi / 180

    /// Whether holding the Pencil still at the end of a stroke snaps it to a shape with the current tool.
    func snapsShapesOnHold(_ controller: CanvasController) -> Bool {
        switch controller.tool {
        case .shape: true
        case .pen, .pencil: controller.pencilSettings.holdToSnapShapes
        case .highlighter, .text, .tape, .eraser, .lasso, .laser: false
        }
    }

    /// Every snap anchor of the page's shapes, except the one with `id`.
    func shapeAnchors(excluding id: UUID? = nil) -> [CGPoint] {
        document.objects.compactMap { $0 as? ShapeObject }.filter { $0.id != id }.flatMap(\.snapAnchors)
    }

    private var shapeSnapReach: CGFloat {
        Self.shapeSnapDistance / inputTransform.scale
    }

    private func recognizerOptions(minimumSize: CGFloat, fallbackToCurve: Bool) -> ShapeRecognizer.Options {
        var options = ShapeRecognizer.Options()
        options.minimumSize = minimumSize / inputTransform.scale
        options.anchors = shapeAnchors()
        options.snapDistance = shapeSnapReach
        options.angleSnap = Self.shapeAngleSnap
        options.fallbackToCurve = fallbackToCurve
        return options
    }

    /// The style a shape made from `stroke` takes: the shape tool's, or the pen's colour and width.
    private func shapeStyle(for stroke: Stroke) -> ShapeStyle? {
        guard let controller else { return nil }
        return controller.tool == .shape ? controller.newShapeStyle : controller.shapeStyle(snapping: stroke)
    }

    private func recognize(_ live: LiveStroke) -> ShapeObject? {
        guard let controller, !live.stroke.brush.erases, let style = shapeStyle(for: live.stroke) else { return nil }
        let isShapeTool = controller.tool == .shape
        let minimum = isShapeTool ? Self.shapeToolMinimumSize : Self.holdShapeMinimumSize
        // With a pen or pencil only a confident shape replaces the ink; the shape tool always makes one.
        let options = recognizerOptions(minimumSize: minimum, fallbackToCurve: isShapeTool)
        return ShapeRecognizer.recognize(live.stroke.points.map(\.location), options: options)?.object(style: style)
    }

    // MARK: Hold to snap

    /// The Pencil was held still at `hold` (canvas space): if the live stroke is a shape, it becomes one,
    /// and the Pencil can keep moving to size it before lifting.
    func snapToShape(_ live: LiveStroke, holdingAt hold: CGPoint) {
        guard let shape = recognize(live) else { return }
        discardLiveStroke()
        shapeSnap = ShapeSnap(original: shape, hold: hold, shape: shape)
        refreshObjects()
        feedback.alignmentOccurred(at: inputTransform.toView(hold))
    }

    /// After the snap, moving the Pencil drags a line's or arrow's end, or scales any other shape about
    /// its centre.
    func updateShapeSnap(to p: CGPoint) {
        guard var snap = shapeSnap else { return }
        if !snap.moved {
            // Ignore the wobble of a Pencil that's still being held.
            guard p.distance(to: snap.hold) * inputTransform.scale > 3 else { return }
            snap.moved = true
        }
        let original = snap.original
        if original.shape.isLinear {
            let start = original.handles[0], end = original.handles[1] + (p - snap.hold)
            snap.shape = original.movingHandle(1, to: snappedHandle(end, from: start, excluding: nil, linear: true))
        } else {
            let b = original.bounds
            let c = CGPoint(x: b.midX, y: b.midY)
            let from = snap.hold.distance(to: c)
            guard from > 1e-3 else { return }
            let s = min(max(p.distance(to: c) / from, 0.2), 5)
            snap.shape = original.applying(CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        }
        shapeSnap = snap
        refreshObjects()
    }

    /// The Pencil lifted (or the touch was cancelled): the snapped shape goes on the page, as one
    /// undoable edit, or away.
    func finishShapeSnap(commit: Bool) {
        guard let snap = shapeSnap else { return }
        shapeSnap = nil
        if commit {
            editDocument { document.addObject(snap.shape) }
        }
        refreshObjects()
    }

    // MARK: Shape tool

    /// Called as a finished stroke is about to be committed. With the shape tool, the stroke becomes the
    /// shape it is (or a curve through it) and true is returned: the shape tool never leaves ink.
    func convertToShape(_ live: LiveStroke) -> Bool {
        guard controller?.tool == .shape, !live.stroke.brush.erases else { return false }
        if let shape = recognize(live) {
            editDocument { document.addObject(shape) }
            refreshObjects()
        }
        return true
    }

    // MARK: Reshaping

    /// The selected shape, when the selection is exactly one shape.
    var selectedShape: ShapeObject? {
        guard selection.strokeIDs.isEmpty, selection.objectIDs.count == 1, let id = selection.objectIDs.first else {
            return nil
        }
        return document.object(id: id) as? ShapeObject
    }

    /// Starts dragging the selected shape's handle under `p` (canvas space), if there is one.
    func beginShapeReshape(at p: CGPoint) -> Bool {
        guard let shape = selectedShape else { return false }
        let reach = Self.handleReach / inputTransform.scale
        let nearest = shape.handles.enumerated()
            .map { ($0.offset, $0.element.distance(to: p)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }
        guard let (index, _) = nearest else { return false }
        lassoSession = .reshaping(ShapeReshape(original: shape, handle: index, offset: shape.handles[index] - p))
        return true
    }

    /// The selection box's handle under `p`. A line or arrow has no box to resize or rotate (its ends are
    /// its handles), so only a touch on it moves it.
    func selectionHandle(at p: CGPoint, box: SelectionBox) -> SelectionHandle? {
        if let shape = selectedShape, shape.shape.isLinear {
            let ends = shape.handles
            let reach = Self.handleReach / inputTransform.scale
            return ShapeRecognizer.distance(from: p, toSegment: ends[0], ends[1]) <= reach ? .move : nil
        }
        return SelectionGeometry.handle(at: p, box: box, reach: Self.handleReach / inputTransform.scale,
                                        rotateDistance: Self.rotateHandleDistance / viewTransform.scale)
    }

    func updateShapeReshape(_ reshape: ShapeReshape, to p: CGPoint) {
        let original = reshape.original
        let target = p + reshape.offset
        let other = original.shape.isLinear ? original.handles[1 - reshape.handle] : nil
        let point = snappedHandle(target, from: other, excluding: original.id, linear: original.shape.isLinear)
        let shape = original.movingHandle(reshape.handle, to: point)
        document.previewObjects([shape])
        refreshObjects()
        selectionBox = SelectionGeometry.box(strokeBounds: [], objects: [shape])
        updateLassoOverlay()
    }

    func finishShapeReshape(_ reshape: ShapeReshape, commit: Bool) {
        let original = reshape.original
        if commit, let shape = document.object(id: original.id) as? ShapeObject, shape != original {
            editDocument { document.replaceObjects(before: [original], after: [shape]) }
        } else {
            document.previewObjects([original])
        }
        refreshObjects()
        updateSelectionBox()
    }

    /// `p` on another shape's anchor if it's close to one; otherwise, for a line's end, straightened onto
    /// the nearest 45° from its other end `from` if it's close to that.
    private func snappedHandle(_ p: CGPoint, from: CGPoint?, excluding id: UUID?, linear: Bool) -> CGPoint {
        let anchored = ShapeRecognizer.snapped(p, anchors: shapeAnchors(excluding: id), within: shapeSnapReach)
        guard anchored == p, linear, let from else { return anchored }
        return ShapeRecognizer.snappedAngle(from: from, to: p, within: Self.shapeAngleSnap)
    }

    /// A shape's own handles: solid knobs in the accent, so they read apart from the box's.
    func drawShapeHandles(_ shape: ShapeObject, accent: UIColor, in ctx: CGContext) {
        let r = Self.handleRadius
        ctx.setFillColor(accent.cgColor)
        ctx.setStrokeColor(paperColor.resolvedColor(with: InkTheme.onPaper).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [])
        for handle in shape.handles {
            let p = viewTransform.toView(handle)
            let circle = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.fillEllipse(in: circle)
            ctx.strokeEllipse(in: circle)
        }
    }

    // MARK: Style

    /// Changes the style of every selected shape, as one undoable edit.
    func restyleSelectedShapes(_ change: (inout ShapeStyle) -> Void) {
        let before = document.objects.filter { selection.objectIDs.contains($0.id) }.compactMap { $0 as? ShapeObject }
        let after = before.map { shape -> ShapeObject in
            var copy = shape
            var style = copy.style
            change(&style)
            copy.style = style
            return copy
        }
        guard after != before else { return }
        editDocument { document.replaceObjects(before: before, after: after) }
        refreshObjects()
        updateSelectionBox()
    }

    /// The first selected shape's style, for the lasso's options; nil when no shape is selected.
    var selectedShapeStyle: ShapeStyle? {
        document.objects.first { selection.objectIDs.contains($0.id) && $0 is ShapeObject }
            .flatMap { ($0 as? ShapeObject)?.style }
    }
}
