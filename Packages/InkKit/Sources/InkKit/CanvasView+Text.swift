import UIKit

/// A text tool touch in progress: a tap makes or edits a text box; a drag draws a new box's width.
struct TextGesture {
    let start: CGPoint
    var end: CGPoint
    /// Whether a text box was being edited when the touch began: a tap then only finishes it.
    let endedEditing: Bool

    /// The new box's outline while dragging (canvas space).
    var draft: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

// MARK: - Text boxes

/// The text tool and editing text boxes in place. The box's text view sits over the page while it's edited
/// and the box itself is hidden from the object layer; when editing ends the result goes on the page as one
/// undoable edit (adding the box, changing it, or removing it if it was emptied).
extension CanvasView {
    /// A text tool drag shorter than this (view points) is a tap.
    static let textDragMinimum: CGFloat = 24

    // MARK: Gestures

    func beginTextGesture(at p: CGPoint) {
        let wasEditing = textEditor != nil
        endEditingText()
        textGesture = TextGesture(start: p, end: p, endedEditing: wasEditing)
    }

    func updateTextGesture(to p: CGPoint) {
        guard var gesture = textGesture else { return }
        gesture.end = p
        textGesture = gesture
        updateLassoOverlay()
    }

    func finishTextGesture(commit: Bool) {
        guard let gesture = textGesture else { return }
        textGesture = nil
        updateLassoOverlay()
        guard commit else { return }
        let draft = gesture.draft
        if max(draft.width, draft.height) * inputTransform.scale < Self.textDragMinimum {
            handleTextTap(at: gesture.start, endedEditing: gesture.endedEditing)
        } else if document.contains(gesture.start) {
            createTextBox(at: draft.origin, width: max(draft.width, TextObject.minimumWidth), viewPoint: nil)
        }
    }

    /// A finger tap with the text tool when fingers don't draw, or anywhere on the page while a box is edited.
    @objc func handleTextFingerTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let wasEditing = textEditor != nil
        endEditingText()
        guard controller?.tool == .text else { return }
        handleTextTap(at: viewTransform.toCanvas(g.location(in: self)), endedEditing: wasEditing)
    }

    /// A tap on tape reveals or hides it; a tap on a box edits it (or ticks the checkbox under the tap); a tap
    /// on the page makes a new box, unless it only finished editing another.
    func handleTextTap(at p: CGPoint, endedEditing: Bool) {
        if !endedEditing, toggleTape(at: p) {
            return // a tap on tape reveals or hides it, with the text tool too
        }
        if let box = textBox(at: p) {
            if let target = box.checkboxTargets().first(where: { $0.rect.contains(p.applying(box.transform.inverted())) }) {
                let toggled = box.togglingCheckbox(at: target.location)
                editDocument { document.replaceObjects(before: [box], after: [toggled]) }
                refreshObjects()
                return
            }
            beginEditingText(box, isNew: false, caretAt: p)
        } else if !endedEditing, document.contains(p) {
            let style = controller?.newTextStyle ?? .standard
            // The caret's line is centred on the tap.
            let origin = CGPoint(x: p.x, y: p.y - style.uiFont.lineHeight / 2)
            createTextBox(at: origin, width: nil, viewPoint: nil)
        }
    }

    /// The topmost text box under `p` (canvas space).
    func textBox(at p: CGPoint) -> TextObject? {
        let tolerance = 6 / max(viewTransform.scale, 1e-6)
        return document.objects.reversed().lazy.compactMap { $0 as? TextObject }.first { $0.contains(p, tolerance: tolerance) }
    }

    /// Starts a new, empty box at `origin` (canvas space), `width` wide or as wide as fits.
    private func createTextBox(at origin: CGPoint, width: CGFloat?, viewPoint _: CGPoint?) {
        let style = controller?.newTextStyle ?? .standard
        let page = document.pageBounds
        let margin: CGFloat = 16
        var origin = origin
        var width = width ?? min(TextObject.defaultWidth, page.maxX - margin - origin.x)
        if width < 120, width < TextObject.defaultWidth {
            // Too near the right edge: start further left so the box isn't a sliver.
            width = min(TextObject.defaultWidth, page.width - 2 * margin)
            origin.x = max(page.minX + margin, page.maxX - margin - width)
        }
        origin.y = min(max(origin.y, page.minY), page.maxY - style.uiFont.lineHeight)
        let box = TextObject(origin: origin, width: width, text: RichText("", style: style))
        beginEditingText(box, isNew: true, caretAt: nil)
    }

    // MARK: Editing

    /// Opens `box` for typing, with the caret nearest `caretAt` (canvas space) or at the end.
    func beginEditingText(_ box: TextObject, isNew: Bool, caretAt: CGPoint?) {
        guard let controller else { return }
        if let other = controller.canvas, other !== self {
            other.endEditingText()
        }
        endEditingText()
        if isEmbedded {
            controller.embeddedCanvasWillInk(self)
        }
        clearSelection()
        let editor = TextBoxEditor(object: box, isNew: isNew)
        editor.onChange = { [weak self] in self?.textEditorDidChange() }
        textEditor = editor
        insertSubview(editor.textView, belowSubview: lassoOverlayView)
        placeTextEditor()
        refreshObjects()
        _ = editor.textView.becomeFirstResponder()
        if let caretAt {
            let local = viewTransform.toView(caretAt)
            let point = editor.textView.convert(local, from: self)
            if let position = editor.textView.closestPosition(to: point) {
                editor.textView.selectedTextRange = editor.textView.textRange(from: position, to: position)
            }
        } else {
            let end = editor.textView.endOfDocument
            editor.textView.selectedTextRange = editor.textView.textRange(from: end, to: end)
        }
        textEditorDidChange()
    }

    /// Finishes editing: the box goes on the page as typed, as one undoable edit. An emptied box is removed.
    func endEditingText() {
        guard let editor = textEditor else { return }
        textEditor = nil
        editor.onChange = nil
        let finished = editor.finishedObject()
        let isBlank = finished.text.isBlank
        editor.textView.delegate = nil
        if editor.textView.isFirstResponder {
            _ = editor.textView.resignFirstResponder()
        }
        editor.textView.removeFromSuperview()
        if let original = editor.original {
            if isBlank {
                editDocument { document.delete(PageSelection(objectIDs: [original.id])) }
            } else if finished != original {
                editDocument { document.replaceObjects(before: [original], after: [finished]) }
            }
        } else if !isBlank {
            editDocument { document.addObject(finished) }
        }
        refreshObjects()
        if isActiveCanvas {
            controller?.textFormatDidChange(nil)
        }
        _ = becomeFirstResponder()
    }

    /// Keeps the text view over its box as the page pans and zooms.
    func placeTextEditor() {
        textEditor?.place(at: viewTransform, screenScale: window?.screen.scale ?? traitCollection.displayScale)
    }

    private func textEditorDidChange() {
        guard let editor = textEditor else { return }
        placeTextEditor()
        if isActiveCanvas || controller?.canvas == nil {
            controller?.textFormatDidChange(editor.formatState)
        }
    }

    /// Applies a format bar change to the box being edited.
    func formatText(_ change: TextFormatChange) {
        textEditor?.apply(change)
    }

    /// The new box's outline while the text tool drags one out.
    func drawTextDraft(in ctx: CGContext, accent: UIColor) {
        guard let gesture = textGesture else { return }
        let draft = gesture.draft
        guard max(draft.width, draft.height) * inputTransform.scale >= Self.textDragMinimum else { return }
        let rect = viewTransform.toView(draft)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(rect)
        ctx.setLineDash(phase: 0, lengths: [])
    }
}
