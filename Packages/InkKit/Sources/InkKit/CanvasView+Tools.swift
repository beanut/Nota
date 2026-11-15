import UIKit

/// A tape or laser tool touch in progress.
enum ToolGesture {
    case tape(TapeGesture)
    case laser(LaserGesture)
}

/// A tape tool drag: a strip from `start` to `end` (canvas space). A drag too short to be a strip is a tap,
/// which reveals or hides the tape under it.
struct TapeGesture {
    let start: CGPoint
    var end: CGPoint
}

/// A laser touch: where it started, and whether it has gone far enough to be more than a tap (which reveals or
/// hides tape, as with any other tool).
struct LaserGesture {
    let start: CGPoint
    var moved = false
}

extension Tool {
    /// Tools whose touches are gestures of their own rather than ink: the text tool, tape and the laser.
    var isGestureTool: Bool {
        switch self {
        case .text, .tape, .laser: true
        case .pen, .pencil, .highlighter, .shape, .eraser, .lasso: false
        }
    }
}

// MARK: - Gesture tools

/// Routes the touches of the tools that don't draw ink (text, tape, laser) from the canvas's input path to
/// each tool's own handling, in `CanvasView+Text`, `+Tape` and `+Laser`.
extension CanvasView {
    func beginToolGesture(at start: CGPoint) {
        switch controller?.tool {
        case .text?:
            beginTextGesture(at: start)
        case .tape?:
            toolGesture = .tape(TapeGesture(start: start, end: start))
        case .laser?:
            toolGesture = .laser(LaserGesture(start: start))
            beginLaser(at: start)
        default:
            break
        }
    }

    /// Feeds a sample to the gesture tool being used, if one is. Returns whether one was.
    func updateToolGesture(to p: CGPoint) -> Bool {
        if textGesture != nil {
            updateTextGesture(to: p)
            return true
        }
        switch toolGesture {
        case var .tape(gesture)?:
            gesture.end = ShapeRecognizer.snappedAngle(from: gesture.start, to: p, within: Self.shapeAngleSnap)
            toolGesture = .tape(gesture)
            refreshObjects()
            return true
        case var .laser(gesture)?:
            if !gesture.moved, p.distance(to: gesture.start) * inputTransform.scale > Self.tapSlop {
                gesture.moved = true
                toolGesture = .laser(gesture)
            }
            moveLaser(to: p)
            return true
        case nil:
            return false
        }
    }

    /// Ends the gesture tool's touch: `commit` is false when the touch was cancelled.
    func finishToolGestures(commit: Bool) {
        if textGesture != nil {
            finishTextGesture(commit: commit)
        }
        guard let gesture = toolGesture else { return }
        toolGesture = nil
        switch gesture {
        case let .tape(tape):
            finishTapeGesture(tape, commit: commit)
        case let .laser(laser):
            endLaser()
            if commit, !laser.moved {
                toggleTape(at: laser.start)
            }
        }
    }

    /// What the gesture tool shows on the page while its touch is down: the strip being drawn.
    var toolGesturePreview: [any PageObject] {
        guard case let .tape(gesture)? = toolGesture, let draft = tapeDraft(gesture) else { return [] }
        return [draft]
    }
}
