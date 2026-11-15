import UIKit

// MARK: - Scribble gestures

extension CanvasView {
    /// Every finished ink stroke on the page as a gesture target. Pixel-eraser strokes are invisible,
    /// so gestures never act on them.
    private func scribbleCandidates(excluding excluded: UUID?) -> [Scribble.Candidate] {
        document.strokes.compactMap { stroke in
            guard !stroke.brush.erases, stroke.id != excluded else { return nil }
            let points = stroke.points.map(\.location)
            return Scribble.Candidate(id: stroke.id, points: points, bounds: LassoGeometry.bounds(of: points))
        }
    }

    /// Called as a finished ink stroke is about to be committed. If it scratched out ink, erases that
    /// ink instead and returns true (the stroke is dropped).
    func scratchOut(with stroke: LiveStroke) -> Bool {
        guard controller?.pencilSettings.scratchOutToErase == true, !stroke.stroke.brush.erases else {
            return false
        }
        let points = stroke.stroke.points.map(\.location)
        guard Scribble.isScratchOut(points, minSize: 24 / inputTransform.scale) else { return false }
        let ids = Scribble.scratchOutTargets(points, candidates: scribbleCandidates(excluding: stroke.stroke.id),
                                             pad: stroke.stroke.brush.maxWidth)
        guard !ids.isEmpty else { return false } // shading or a zigzag over blank paper: keep it as ink
        for id in ids {
            forgetGeometry(id)
        }
        editDocument { document.recordErase(document.remove(ids: ids)) }
        dropOrphanedPendingStrokes() // also prunes the selection and clears the live layer
        requestFullRender()
        if let last = points.last {
            feedback.pathCompleted(at: inputTransform.toView(last))
        }
        return true
    }

    /// Starts watching the live stroke for circle-and-hold.
    func startHoldWatch(at location: CGPoint, time: TimeInterval) {
        stopHoldWatch()
        // A stroke along the ruler is straight already: holding at its end mustn't turn it into a shape.
        guard let controller, live != nil, rulerSnap == nil,
              controller.pencilSettings.circleToSelect || snapsShapesOnHold(controller) else { return }
        lastMovement = (location, time)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHold() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    func stopHoldWatch() {
        holdTimer?.invalidate()
        holdTimer = nil
        lastMovement = nil
    }

    /// Records Pencil movement for the hold check. Movement under 3 points doesn't count.
    func noteMovement(at location: CGPoint, time: TimeInterval) {
        guard holdTimer != nil, let last = lastMovement, last.location.distance(to: location) > 3 else { return }
        lastMovement = (location, time)
    }

    /// The Pencil has been still for a moment: if the live stroke is a loop around ink, select that ink;
    /// otherwise, if it's a shape, snap it to one.
    private func checkHold() {
        guard let last = lastMovement, let live, let controller,
              ProcessInfo.processInfo.systemUptime - last.time >= 0.45 else { return }
        stopHoldWatch() // one check per stroke once it's held
        let loop = live.stroke.points.map(\.location)
        let ids: Set<UUID> = controller.pencilSettings.circleToSelect && controller.tool != .shape
            && Scribble.isClosedLoop(loop, minSize: 24 / inputTransform.scale)
            ? Scribble.loopSelection(loop, candidates: scribbleCandidates(excluding: live.stroke.id)) : []
        guard !ids.isEmpty else {
            if snapsShapesOnHold(controller) {
                snapToShape(live, holdingAt: inputTransform.toCanvas(last.location))
            }
            return
        }
        // The loop becomes a selection: drop its ink, switch to the lasso and keep the Pencil down to
        // drag what it caught.
        discardLiveStroke()
        controller.select(.lasso)
        dropPending(ids) // they're redrawn where they move to
        select(PageSelection(strokeIDs: ids))
        if let box = selectionBox {
            lassoSession = .transforming(SelectionDrag(handle: .move, start: inputTransform.toCanvas(last.location),
                                                       box: box, session: document.beginTransform(selection)))
        }
        feedback.alignmentOccurred(at: last.location)
    }
}
