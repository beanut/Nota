import UIKit

// MARK: - Input

/// Touches into ink: the touch phases, coalesced and predicted samples, estimated-property updates, palm
/// rejection and finger ink, feeding `LiveStroke` (or the eraser, the lasso and the tools). A finished
/// stroke goes to the `RenderCoordinator` (`endStroke(commit:)`). The state is `CanvasInput`'s.
extension CanvasView {
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
            input.palmRejector.pencilSeen(at: touch.location(in: self), time: touch.timestamp)
        }
        let priorDirectTouches = event?.allTouches?.filter {
            isFinger($0) && !touches.contains($0) && $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        // A second finger soon after finger ink began: it was the start of a pinch, pan or tap, not ink.
        if let active = activeTouch, active.type == .direct, let finger = touches.first(where: { isFinger($0) }),
           finger.timestamp - input.strokeBeganAt < 0.3 {
            endStroke(commit: false)
        }
        if priorDirectTouches == 0, viewport.activeGestureCount == 0, touches.contains(where: { isFinger($0) }) {
            viewport.gestureStartTransform = viewTransform
            viewport.didTransformInTouchSequence = false
        }
        if settleLink != nil {
            finishSettling()
        } // never draw on a page that's still sliding
        if priorDirectTouches == 0 {
            viewport.maxDirectTouchesInSequence = 0
            viewport.didPinchInSequence = false
        }
        let directTouches = priorDirectTouches + touches.filter { isFinger($0) }.count
        viewport.maxDirectTouchesInSequence = max(viewport.maxDirectTouchesInSequence, directTouches)
        for touch in touches {
            if activeTouch == nil, beginZoomDrag(touch) {
                continue
            }
            guard isDrawingTouch(touch, event: event), activeTouch == nil, viewport.activeGestureCount == 0,
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
            input.strokeBeganAt = touch.timestamp
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
        input.palmTouches.subtract(touches)
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
        input.palmTouches.subtract(touches)
    }

    /// The next event of the stroke under way.
    func moveStroke(_ touch: UITouch, event: UIEvent?) {
        if touch.type == .pencil {
            input.palmRejector.pencilSeen(at: touch.location(in: self), time: touch.timestamp)
        } else if isPalm(touch) {
            endStroke(commit: false) // finger ink whose contact grew into a palm
            return
        }
        ingest(touch, event: event, final: false)
    }

    /// Starts this page's piece of a stroke begun on another page (or of this page's own stroke, back
    /// after leaving it), as it comes within reach. The piece may start off the page.
    func joinStroke(_ touch: UITouch, event: UIEvent?, group: UUID) {
        guard activeTouch == nil, viewport.activeGestureCount == 0, zoomTouch == nil else { return }
        activeTouch = touch
        strokeGroup = group
        joinedStroke = true
        input.strokeBeganAt = touch.timestamp
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
            guard let key = touch.estimationUpdateIndex, let ref = input.estimates.point(for: key) else { continue }
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
            } else if let pendingStroke = coordinator.awaitingStroke(ref.strokeID),
                      pendingStroke.live.stroke.points.indices.contains(ref.index) {
                apply(&pendingStroke.live.stroke.points[ref.index])
                let wasCurrent = pendingStroke.revisionAfter == document.inkVersion
                _ = editDocument { document.updatePoint(strokeID: ref.strokeID, index: ref.index, apply) }
                // Only while nothing else changed since: otherwise drawing it can't bring the bitmap level.
                pendingStroke.revisionAfter = wasCurrent ? document.inkVersion : -1
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
                coordinator.forgetGeometry(ref.strokeID)
            } else if editDocument({ document.updatePoint(strokeID: ref.strokeID, index: ref.index, apply) }) {
                coordinator.forgetGeometry(ref.strokeID)
                coordinator.invalidateAll()
            }
            if touch.estimatedPropertiesExpectingUpdates.isEmpty {
                if let live, live.stroke.id == ref.strokeID {
                    live.unsettledPoints.remove(ref.index)
                } else {
                    coordinator.pendingStroke(ref.strokeID)?.live.unsettledPoints.remove(ref.index)
                }
                input.estimates.resolve(key)
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
        coordinator.refreshPendingGeometry()
        if !pendingDirty.isNull {
            invalidateLive(canvasRect: pendingDirty)
        }
        coordinator.schedulePendingCommit()
    }

    /// `start` is the touch-down point in canvas space. Ink only starts on the page; erasing and the
    /// lasso work from anywhere, since they may need to reach strokes hanging off the edge.
    private func beginStroke(at start: CGPoint, offPage: Bool = false) {
        guard let controller else { return }
        input.estimates.pruneIfOverflowing()
        input.fingerPrevious = nil
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
            input.estimates.expect(key, strokeID: live.stroke.id, index: index)
            live.unsettledPoints.insert(index)
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

    func endStroke(commit: Bool) {
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
            // A piece joined from another page is only kept if it reached this one; it's never a tap or a shape.
            if commit, !live.stroke.points.isEmpty, joined ? !isOffPage(live) : !tapObjectIfTapped(live) && !convertToShape(live) {
                if let (segment, dirty) = live.finish() { // the end taper, now the end is known
                    liveView.geometryChanged(of: live, fromSegment: segment, canvasRect: dirty)
                    zoomPanel?.liveView.geometryChanged(of: live, fromSegment: segment, canvasRect: dirty)
                    invalidateLive(canvasRect: dirty)
                }
                let geom = live.geometry()
                coordinator.cache(geom, for: live.stroke.id)
                let splits = live.stroke.brush.erases
                    ? splits(cutBy: live.stroke, hulls: live.allHulls) : []
                let revisionBefore = document.inkVersion
                editDocument { document.add(live.stroke, splits: splits) }
                coordinator.strokeCommitted(live, geometry: geom, revisionBefore: revisionBefore)
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

    func updateFingerState(_ event: UIEvent?, ending: Set<UITouch> = []) {
        guard activeTouch == nil else { return }
        let fingers = event?.allTouches?.filter {
            isFinger($0) && !ending.contains($0) && $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        hud.state = fingers > 0 ? .finger(fingers) : (hoverActive ? .hovering : .idle)
        publishHUD(force: true)
    }

    func publishHUD(force: Bool) {
        guard let telemetry, controller?.hudVisible == true else { return }
        let now = ProcessInfo.processInfo.systemUptime // same clock as UITouch.timestamp
        hud.samplesPerSecond = sampleRate.rate(at: now)
        hud.eventsPerSecond = eventRate.rate(at: now)
        hud.pendingEstimates = input.estimates.count
        hud.strokeCount = document.strokes.count
        telemetry.submit(hud, immediately: force)
    }

    // MARK: - Palm rejection and finger ink

    /// Whether a finger draws ink, from the Pencil settings and the system's Only Draw with Apple Pencil.
    var fingerDraws: Bool {
        (controller?.pencilSettings.fingerDrawing ?? .system)
            .fingerDraws(pencilOnlySystemSetting: UIPencilInteraction.prefersPencilOnlyDrawing)
    }

    /// A direct touch that isn't a resting palm.
    func isFinger(_ touch: UITouch) -> Bool {
        touch.type == .direct && !isPalm(touch)
    }

    /// Classifies a direct touch when it's first seen (by a gesture recognizer or `touchesBegan`) and
    /// again as its contact grows: once a palm, it stays one until it lifts.
    func isPalm(_ touch: UITouch) -> Bool {
        guard touch.type == .direct else { return false }
        if input.palmTouches.contains(touch) {
            return true
        }
        if input.palmRejector.rejects(location: touch.location(in: self), radius: touch.majorRadius,
                                      time: touch.timestamp) {
            input.palmTouches.insert(touch)
            return true
        }
        return false
    }

    /// Re-reads the settings the canvas caches: palm rejection and how many fingers pan.
    func pencilSettingsDidChange() {
        if let settings = controller?.pencilSettings {
            input.palmRejector.sensitivity = settings.palmRejection
            input.palmRejector.handedness = settings.handedness
        }
        pan.minimumNumberOfTouches = fingerDraws ? 2 : 1 // one finger draws, so two pan
    }

    /// Finger ink (and the simulator's stand-in Pencil) has no pressure, so it's faked from drag speed:
    /// slow = heavy, fast = light, low-passed so the width changes smoothly.
    private func fingerPoint(_ touch: UITouch, viewLocation: CGPoint, canvasLocation: CGPoint,
                             predicted: Bool) -> StrokePoint {
        let force = input.fingerForce(at: viewLocation, time: touch.timestamp, predicted: predicted)
        #if targetEnvironment(simulator)
            let altitude = controller?.simulatedAltitude ?? .pi / 2
        #else
            let altitude = CGFloat.pi / 2
        #endif
        return StrokePoint(location: canvasLocation, force: force, altitude: altitude,
                           azimuth: -.pi / 4, timestamp: touch.timestamp)
    }
}
