import UIKit

/// A change the format bar (or the Pen Case's colours) makes to the text box being edited: to the selected
/// text, or to what's typed next when nothing is selected, and for paragraph changes to every paragraph
/// the selection touches.
enum TextFormatChange: Equatable {
    case font(TextFont)
    case size(CGFloat)
    case color(PenColor)
    case bold(Bool)
    case italic(Bool)
    case underline(Bool)
    case alignment(TextAlignment)
    case list(TextList)
    /// Moves paragraphs this many outline levels in (positive) or out.
    case indent(Int)
}

/// What the format bar shows: the style and paragraph at the start of the selection.
struct TextFormatState: Equatable {
    var style: TextStyle
    var alignment: TextAlignment
    var list: TextList
    var indent: Int
}

/// The text view a text box is edited in. It's laid out exactly like `TextLayout` (TextKit 1, no padding or
/// insets) and sits over the box at the box's own scale and rotation, so the text doesn't move when
/// editing starts or ends. List markers are drawn behind the text by `markers`; checkboxes are buttons.
final class InkTextView: UITextView {
    let markers = MarkerView()
    private var checkboxButtons: [UIButton] = []
    var onToggleCheckbox: ((Int) -> Void)?
    var onIndent: ((Int) -> Void)?

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        TextLayout.configure(container)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        super.init(frame: .zero, textContainer: container)
        backgroundColor = .clear
        isScrollEnabled = false
        textContainerInset = .zero
        allowsEditingTextAttributes = true
        clipsToBounds = false
        layer.anchorPoint = .zero
        markers.textView = self
        markers.isUserInteractionEnabled = false
        markers.backgroundColor = .clear
        markers.isOpaque = false
        insertSubview(markers, at: 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pasted text takes the box's style rather than bringing another app's fonts and colours.
    override func paste(_: Any?) {
        guard let string = UIPasteboard.general.string else { return }
        insertText(string)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Outdent", action: #selector(outdent), input: "\t", modifierFlags: .shift)]
    }

    @objc private func outdent() {
        onIndent?(-1)
    }

    /// The typing attributes, when they style a last paragraph that has no characters yet (the caret is
    /// at the very end); nil otherwise, when the text's own attributes do.
    var trailingAttributes: [NSAttributedString.Key: Any]? {
        selectedRange.location == textStorage.length ? typingAttributes : nil
    }

    /// Redraws the markers and puts a button on every checkbox.
    func layoutMarkers() {
        markers.frame = CGRect(origin: .zero, size: bounds.size)
        markers.setNeedsDisplay()
        let slots = TextLayout.markerSlots(manager: layoutManager, storage: textStorage, trailing: trailingAttributes)
            .filter {
                if case .checkbox = $0.marker {
                    true
                } else {
                    false
                }
            }
        while checkboxButtons.count > slots.count {
            checkboxButtons.removeLast().removeFromSuperview()
        }
        while checkboxButtons.count < slots.count {
            let button = UIButton(type: .custom)
            button.accessibilityLabel = "Checkbox"
            button.addTarget(self, action: #selector(checkboxTapped(_:)), for: .primaryActionTriggered)
            addSubview(button)
            checkboxButtons.append(button)
        }
        for (button, slot) in zip(checkboxButtons, slots) {
            let side = max(slot.box.width + 12, 30)
            button.frame = CGRect(x: slot.box.midX - side / 2, y: slot.box.midY - side / 2, width: side, height: side)
            button.tag = slot.location
            if case let .checkbox(checked) = slot.marker {
                button.accessibilityValue = checked ? "Checked" : "Unchecked"
            }
        }
    }

    @objc private func checkboxTapped(_ button: UIButton) {
        onToggleCheckbox?(button.tag)
    }

    /// Draws the list markers of the text view it belongs to, behind the text.
    final class MarkerView: UIView {
        weak var textView: InkTextView?

        override func draw(_: CGRect) {
            guard let textView, let ctx = UIGraphicsGetCurrentContext() else { return }
            TextLayout.drawMarkers(manager: textView.layoutManager, storage: textView.textStorage,
                                   trailing: textView.trailingAttributes, origin: .zero, in: ctx)
        }
    }
}

/// Edits one text box in place: the box as it was (nil for a new one), the box as it is now, and the text
/// view it's being typed into. The canvas owns it while the box is being edited (see `CanvasView+Text`)
/// and records the result as one undoable edit when editing ends.
@MainActor
final class TextBoxEditor: NSObject, UITextViewDelegate {
    let original: TextObject?
    private(set) var object: TextObject
    let textView = InkTextView()
    /// The layout of the paragraph Return is starting, when it continues a list: UIKit doesn't carry our
    /// own attributes across a typed newline, so `repairParagraphs()` puts them back from here.
    private var continuedFormat: TextParagraphFormat?
    /// Called when the box's height or the format at the caret changes.
    var onChange: (() -> Void)?

    init(object: TextObject, isNew: Bool) {
        original = isNew ? nil : object
        self.object = object
        super.init()
        textView.delegate = self
        textView.attributedText = object.text.attributedString()
        let last = object.text.paragraphs[object.text.paragraphs.count - 1]
        textView.typingAttributes = last.runs[last.runs.count - 1].style.attributes(in: TextParagraphFormat(last))
        textView.onToggleCheckbox = { [weak self] location in self?.toggleCheckbox(at: location) }
        textView.onIndent = { [weak self] delta in self?.apply(.indent(delta)) }
        relayout()
    }

    var objectID: UUID {
        object.id
    }

    /// The text as typed so far.
    var text: RichText {
        RichText(textView.attributedText, trailing: textView.trailingAttributes)
    }

    /// The box with the text as typed, ready to go on the page.
    func finishedObject() -> TextObject {
        var finished = object
        finished.setText(text.trimmed())
        return finished
    }

    /// Puts the text view over the box at `viewTransform`, rendering its text sharply at that zoom.
    func place(at viewTransform: ViewTransform, screenScale: CGFloat) {
        let f = object.frame
        textView.layer.position = .zero
        textView.transform = CGAffineTransform(translationX: f.minX, y: f.minY)
            .concatenating(object.transform)
            .concatenating(viewTransform.affine)
        let scale = min(max(screenScale * viewTransform.scale * object.scale, 1), 12)
        setContentScale(scale, of: textView)
    }

    private func setContentScale(_ scale: CGFloat, of view: UIView) {
        if abs(view.contentScaleFactor - scale) > 0.01 {
            view.contentScaleFactor = scale
            view.setNeedsDisplay()
        }
        for subview in view.subviews {
            setContentScale(scale, of: subview)
        }
    }

    /// Fits the text view and the box to the text's height.
    private func relayout() {
        // UITextView makes its container track its bounds; the box grows with its text instead.
        let container = textView.textContainer
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        let size = CGSize(width: object.frame.width, height: .greatestFiniteMagnitude)
        if container.size != size {
            container.size = size
        }
        let font = (textView.typingAttributes[.font] as? UIFont) ?? TextStyle.standard.uiFont
        let height = TextLayout.usedHeight(manager: textView.layoutManager, container: textView.textContainer,
                                           minimumLine: font.lineHeight)
        object.frame.size.height = height
        textView.bounds = CGRect(x: 0, y: 0, width: object.frame.width, height: height)
        textView.contentOffset = .zero
        textView.layoutMarkers()
        onChange?()
    }

    /// The style and paragraph at the caret, for the format bar.
    var formatState: TextFormatState {
        let attributes: [NSAttributedString.Key: Any]
        let range = textView.selectedRange
        if range.length > 0 {
            attributes = textView.textStorage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }
        let paragraph = paragraphAttributes(at: range.location)
        let format = TextParagraphFormat(attributes: paragraph)
        return TextFormatState(style: TextStyle(attributes: attributes), alignment: format.alignment,
                               list: format.list, indent: format.indent)
    }

    /// The attributes that set the layout of the paragraph holding character `location`.
    private func paragraphAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        let ns = textView.textStorage.string as NSString
        let range = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
        if range.length > 0 {
            return textView.textStorage.attributes(at: range.location, effectiveRange: nil)
        }
        return textView.typingAttributes
    }

    // MARK: Formatting

    func apply(_ change: TextFormatChange) {
        switch change {
        case let .font(font): changeCharacters { $0.font = font }
        case let .size(size): changeCharacters { $0.size = size }
        case let .color(color): changeCharacters { $0.color = color }
        case let .bold(on): changeCharacters { $0.bold = on }
        case let .italic(on): changeCharacters { $0.italic = on }
        case let .underline(on): changeCharacters { $0.underline = on }
        case let .alignment(alignment): changeParagraphs(in: textView.selectedRange) { $0.alignment = alignment }
        case let .list(list): changeParagraphs(in: textView.selectedRange) { $0.list = list }
        case let .indent(delta):
            changeParagraphs(in: textView.selectedRange) {
                $0.indent = min(max($0.indent + delta, 0), TextParagraph.maxIndent)
            }
        }
    }

    /// Restyles the selected characters, and what's typed next.
    private func changeCharacters(_ modify: (inout TextStyle) -> Void) {
        let storage = textView.textStorage
        let range = textView.selectedRange
        if range.length > 0 {
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                storage.setAttributes(Self.restyled(attributes, modify), range: run)
            }
            storage.endEditing()
        }
        textView.typingAttributes = Self.restyled(textView.typingAttributes, modify)
        textChanged()
    }

    private static func restyled(_ attributes: [NSAttributedString.Key: Any],
                                 _ modify: (inout TextStyle) -> Void) -> [NSAttributedString.Key: Any] {
        var style = TextStyle(attributes: attributes)
        modify(&style)
        var result = style.attributes(in: TextParagraphFormat(attributes: attributes))
        // The paragraph keeps its own layout (its indent follows its first character's size).
        result[.paragraphStyle] = attributes[.paragraphStyle] ?? result[.paragraphStyle]
        return result
    }

    /// Changes the layout of every paragraph `range` touches (and of what's typed next).
    private func changeParagraphs(in range: NSRange, _ modify: (inout TextParagraphFormat) -> Void) {
        let storage = textView.textStorage
        let ns = storage.string as NSString
        let selected = range.location <= ns.length ? ns.paragraphRange(for: range) : NSRange(location: ns.length, length: 0)
        storage.beginEditing()
        var location = selected.location
        while location < NSMaxRange(selected) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let first = storage.attributes(at: paragraph.location, effectiveRange: nil)
            var format = TextParagraphFormat(attributes: first)
            modify(&format)
            let size = TextStyle(attributes: first).size
            storage.enumerateAttributes(in: paragraph) { attributes, run, _ in
                storage.setAttributes(Self.reformatted(attributes, format, size: size), range: run)
            }
            location = max(NSMaxRange(paragraph), location + 1)
        }
        storage.endEditing()
        // What's typed next follows the caret's paragraph. The last paragraph may have no characters yet:
        // then the typing attributes are all there is of it.
        let typing = textView.typingAttributes
        let caret = textView.selectedRange.location
        let caretParagraph = ns.paragraphRange(for: NSRange(location: min(caret, ns.length), length: 0))
        var format = TextParagraphFormat(attributes: typing)
        if caretParagraph.length > 0 {
            format = TextParagraphFormat(attributes: storage.attributes(at: caretParagraph.location, effectiveRange: nil))
        } else if NSMaxRange(range) >= ns.length {
            modify(&format)
        }
        textView.typingAttributes = Self.reformatted(typing, format, size: TextStyle(attributes: typing).size)
        textChanged()
    }

    private static func reformatted(_ attributes: [NSAttributedString.Key: Any], _ format: TextParagraphFormat,
                                    size: CGFloat) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result[.paragraphStyle] = TextLayout.paragraphStyle(format, size: size)
        result[.inkList] = format.list.rawValue
        result[.inkChecked] = format.checked
        result[.inkIndent] = format.indent
        return result
    }

    /// Ticks or unticks the checkbox of the paragraph starting at `location`.
    func toggleCheckbox(at location: Int) {
        changeParagraphs(in: NSRange(location: location, length: 0)) { $0.checked.toggle() }
    }

    private func textChanged() {
        relayout()
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let paragraph = TextParagraphFormat(attributes: paragraphAttributes(at: range.location))
        guard paragraph.list != .none, range.length == 0 else { return true }
        let ns = textView.textStorage.string as NSString
        let paragraphRange = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let body = ns.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
        switch text {
        case "\n":
            if body.isEmpty {
                // Return on an empty item ends the list (or steps out a level).
                changeParagraphs(in: range) {
                    if $0.indent > 0 {
                        $0.indent -= 1
                    } else {
                        $0.list = .none
                    }
                }
                return false
            }
            var next = paragraph
            next.checked = false // the next item starts unticked
            continuedFormat = next
            return true
        case "\t":
            apply(.indent(1))
            return false
        default:
            return true
        }
    }

    func textViewDidChange(_: UITextView) {
        repairParagraphs()
        relayout()
    }

    /// Gives every paragraph one layout throughout, and characters typed without our attributes (UIKit
    /// drops them from typed text now and then) their paragraph's. A paragraph with none of its own takes
    /// the list Return continued, or else what its paragraph style says (alignment and indent).
    private func repairParagraphs() {
        let storage = textView.textStorage
        let ns = storage.string as NSString
        let caretParagraph = ns.paragraphRange(for: NSRange(location: min(textView.selectedRange.location, ns.length),
                                                            length: 0))
        var caretFormat: TextParagraphFormat?
        storage.beginEditing()
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var format: TextParagraphFormat?
            storage.enumerateAttribute(.inkList, in: paragraph) { value, run, stop in
                if value != nil {
                    format = TextParagraphFormat(attributes: storage.attributes(at: run.location, effectiveRange: nil))
                    stop.pointee = true
                }
            }
            let first = storage.attributes(at: paragraph.location, effectiveRange: nil)
            let size = TextStyle(attributes: first).size
            if format == nil {
                if let continued = continuedFormat, paragraph.location == caretParagraph.location {
                    format = continued
                } else {
                    format = Self.format(fromStyleIn: first, size: size)
                }
            }
            let resolved = format ?? TextParagraphFormat()
            storage.enumerateAttributes(in: paragraph) { attributes, run, _ in
                if attributes[.inkList] == nil || TextParagraphFormat(attributes: attributes) != resolved {
                    storage.setAttributes(Self.reformatted(attributes, resolved, size: size), range: run)
                }
            }
            if paragraph.location == caretParagraph.location {
                caretFormat = resolved
            }
            location = max(NSMaxRange(paragraph), location + 1)
        }
        storage.endEditing()
        let typing = textView.typingAttributes
        if caretFormat == nil {
            // The caret is on a last paragraph with no characters yet.
            caretFormat = typing[.inkList] != nil ? TextParagraphFormat(attributes: typing)
                : continuedFormat ?? Self.format(fromStyleIn: typing, size: TextStyle(attributes: typing).size)
        }
        if let caretFormat {
            textView.typingAttributes = Self.reformatted(typing, caretFormat, size: TextStyle(attributes: typing).size)
        }
        continuedFormat = nil
    }

    /// A paragraph's layout as far as its paragraph style alone tells: its alignment, and its indent if
    /// it isn't in a list.
    private static func format(fromStyleIn attributes: [NSAttributedString.Key: Any], size: CGFloat) -> TextParagraphFormat {
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        let indent = Int(((style?.headIndent ?? 0) / TextLayout.indentStep(size: size)).rounded())
        return TextParagraphFormat(alignment: style.map { TextAlignment($0.alignment) } ?? .left, indent: indent)
    }

    func textViewDidChangeSelection(_: UITextView) {
        textView.layoutMarkers()
        onChange?()
    }
}
