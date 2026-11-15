import UIKit

/// A finger tap that reveals or hides tape, when fingers don't draw (when they do, a tap is a tiny stroke,
/// and `toggleTapeIfTapped(_:)` catches it instead).
final class TapeTapGestureRecognizer: UITapGestureRecognizer {}

extension Tool {
    /// Whether a tap with this tool on tape reveals or hides it. The lasso selects tape instead (to move it or
    /// delete it), and the eraser never touches objects.
    var togglesTape: Bool {
        switch self {
        case .lasso, .eraser: false
        case .pen, .pencil, .highlighter, .shape, .text, .tape, .laser: true
        }
    }
}

// MARK: - Tape

/// The tape tool and revealing or hiding tape with a tap. Tape is a page object (`TapeObject`) drawn over the
/// ink in `tapeLayer`; each strip added, revealed or hidden is one undoable edit, so it's saved with the note.
extension CanvasView {
    /// A touch shorter than this (seconds) that stays within `tapSlop` is a tap on tape, not ink.
    static let tapeTapDuration: TimeInterval = 0.5

    /// The topmost tape under `p` (canvas space), if any.
    func tape(at p: CGPoint) -> TapeObject? {
        let tolerance = 2 / max(viewTransform.scale, 1e-6)
        return document.objects.reversed().lazy.compactMap { $0 as? TapeObject }
            .first { $0.contains(p, tolerance: tolerance) }
    }

    /// Reveals or hides the topmost tape under `p` (canvas space), as one undoable edit. Returns false if
    /// there's no tape there.
    @discardableResult
    func toggleTape(at p: CGPoint) -> Bool {
        guard let tape = tape(at: p) else { return false }
        _ = editDocument { document.toggleTape(id: tape.id) }
        refreshObjects()
        feedback.alignmentOccurred(at: inputTransform.toView(p))
        return true
    }

    /// Called as a finished stroke is about to be committed: a tap (a tiny, quick stroke) on tape with a tool
    /// that toggles tape reveals or hides it instead of leaving a dot, and true is returned.
    func toggleTapeIfTapped(_ live: LiveStroke) -> Bool {
        guard let controller, controller.tool.togglesTape, !live.stroke.brush.erases,
              let first = live.stroke.points.first, let last = live.stroke.points.last,
              last.timestamp - first.timestamp <= Self.tapeTapDuration else { return false }
        let extent = LassoGeometry.bounds(of: live.stroke.points.map(\.location))
        guard max(extent.width, extent.height) * inputTransform.scale <= Self.tapSlop else { return false }
        return toggleTape(at: first.location)
    }

    /// The strip a tape drag would put on the page, or nil while it's still short enough to be a tap.
    func tapeDraft(_ gesture: TapeGesture) -> TapeObject? {
        guard let controller, gesture.start.distance(to: gesture.end) * inputTransform.scale > Self.tapSlop else {
            return nil
        }
        let width = CGFloat(controller.settings[.tape]?.width ?? Double(TapeObject.defaultWidth))
        return TapeObject(from: gesture.start, to: gesture.end, width: width, color: controller.color(for: .tape),
                          pattern: controller.tapePattern)
    }

    /// The tape tool's touch lifted: a drag puts its strip on the page (hidden, covering what's under it); a
    /// tap reveals or hides the tape under it.
    func finishTapeGesture(_ gesture: TapeGesture, commit: Bool) {
        defer { refreshObjects() }
        guard commit else { return }
        if let draft = tapeDraft(gesture) {
            guard document.contains(gesture.start) else { return }
            editDocument { document.addObject(draft) }
        } else {
            toggleTape(at: gesture.start)
        }
    }

    /// Reveals or hides all of the page's tape, as one undoable edit.
    func setAllTape(revealed: Bool) {
        guard editDocument({ document.setAllTape(revealed: revealed) }) > 0 else { return }
        refreshObjects()
    }

    // MARK: Finger taps

    func installTapeTap() {
        let tap = TapeTapGestureRecognizer(target: self, action: #selector(handleTapeTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    /// A finger tap toggles tape when fingers don't draw, with any tool that toggles tape. The text tool's own
    /// finger tap does it for the text tool (`handleTextTap`).
    func tapeTapShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard !fingerDraws, let tool = controller?.tool, tool.togglesTape, tool != .text, textEditor == nil else {
            return false
        }
        return tape(at: viewTransform.toCanvas(g.location(in: self))) != nil
    }

    @objc func handleTapeTap(_ g: TapeTapGestureRecognizer) {
        guard g.state == .ended else { return }
        toggleTape(at: viewTransform.toCanvas(g.location(in: self)))
    }
}
