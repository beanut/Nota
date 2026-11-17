import UIKit

/// A typed text box on the page: rich text (`RichText`) laid out in a column `frame.width` wide, growing
/// down as it's written. Made with the text tool and edited in place (`TextBoxEditor`), with the keyboard
/// or by writing into it with the Pencil (Scribble).
///
/// **Geometry.** `frame.origin` is the box's top-left in its own space and `frame.width` the width its text
/// wraps at; `frame.height` always follows the text. The transform only ever moves, rotates and uniformly
/// scales the box: resizing it with the selection box changes the width the text wraps at rather than
/// stretching the letters (`applying(_:)`), so text keeps its size wherever it's dragged.
///
/// **Drawing.** TextKit lays the text out, the same way the editor's text view does, so a box looks the same
/// while it's edited and after. Drawn into a PDF, the text stays real text.
///
/// File kind `"text"`; its own field is `text` (see `RichText` for its shape).
public struct TextObject: PageObject, Equatable {
    public static let kind = "text"

    public let id: UUID
    public var frame: CGRect
    public var transform: CGAffineTransform
    public var zIndex: Int
    public private(set) var text: RichText

    /// The narrowest a box can be made, in its own points.
    public static let minimumWidth: CGFloat = 40
    /// How wide a box made with a tap is, in page points (narrower near the page's edge).
    public static let defaultWidth: CGFloat = 320

    /// A box with its top-left at `origin` (its own space), wrapping at `width`.
    public init(id: UUID = UUID(), origin: CGPoint, width: CGFloat, text: RichText,
                transform: CGAffineTransform = .identity, zIndex: Int = 0) {
        self.id = id
        self.text = text
        self.transform = transform
        self.zIndex = zIndex
        let width = max(width, Self.minimumWidth)
        frame = CGRect(origin: origin, size: CGSize(width: width, height: TextLayout.height(of: text, width: width)))
    }

    /// The text without formatting, for search and export.
    public var plainText: String {
        text.plainText
    }

    /// Replaces the text; the box's height follows it.
    public mutating func setText(_ text: RichText) {
        self.text = text
        frame.size.height = TextLayout.height(of: text, width: frame.width)
    }

    /// The box wrapping at `width` (its own points); its height follows.
    public func resized(toWidth width: CGFloat) -> TextObject {
        var copy = self
        copy.frame.size.width = max(width, Self.minimumWidth)
        copy.frame.size.height = TextLayout.height(of: text, width: copy.frame.width)
        return copy
    }

    /// How much the box's own points are scaled on the page (its text's scale).
    public var scale: CGFloat {
        max(hypot(transform.c, transform.d), 1e-6)
    }

    /// Moved, rotated or resized with the selection: the box goes where `t` takes its top-left corner and
    /// turns with it, but its text keeps its scale. Stretching it changes the width the text wraps at.
    public func applying(_ t: CGAffineTransform) -> TextObject {
        let m = transform.concatenating(t)
        let along = hypot(m.a, m.b)
        guard along > 1e-9, m.a * m.d - m.b * m.c > 0 else { return self }
        let s = scale
        let angle = atan2(m.b, m.a)
        var placed = CGAffineTransform(a: s * cos(angle), b: s * sin(angle), c: -s * sin(angle), d: s * cos(angle),
                                       tx: 0, ty: 0)
        let corner = frame.origin.applying(m), mapped = frame.origin.applying(placed)
        placed.tx = corner.x - mapped.x
        placed.ty = corner.y - mapped.y
        let width = frame.width * along / s
        var copy = abs(width - frame.width) > 0.01 ? resized(toWidth: width) : self
        copy.transform = placed
        return copy
    }

    public func recolored(_ color: PenColor) -> TextObject {
        var copy = self
        copy.text = text.recolored(color)
        return copy
    }

    public func draw(in ctx: CGContext) {
        TextLayout.using(text, width: frame.width) { $0.draw(at: frame.origin, in: ctx) }
    }

    /// The checkboxes' touch targets in the box's own space, with the character index that starts each
    /// one's paragraph.
    func checkboxTargets() -> [(rect: CGRect, location: Int)] {
        TextLayout.cached(text, width: frame.width).checkboxes().map { box in
            (box.rect.offsetBy(dx: frame.minX, dy: frame.minY), box.location)
        }
    }

    /// The box with the checkbox of the paragraph starting at character `location` ticked or unticked.
    func togglingCheckbox(at location: Int) -> TextObject {
        var paragraphs = text.paragraphs
        var start = 0
        for i in paragraphs.indices {
            if start == location, paragraphs[i].list == .checkbox {
                paragraphs[i].checked.toggle()
                var copy = self
                copy.text = RichText(paragraphs: paragraphs)
                return copy
            }
            start += (paragraphs[i].text as NSString).length + 1
        }
        return self
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case text
    }

    public init(from decoder: Decoder) throws {
        let placement = try PageObjectPlacement(from: decoder)
        id = placement.id
        transform = placement.transform
        zIndex = placement.zIndex
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(RichText.self, forKey: .text)) ?? RichText("")
        frame = placement.frame
        frame.size.width = max(frame.width, Self.minimumWidth)
    }

    public func encode(to encoder: Encoder) throws {
        try PageObjectPlacement(of: self).encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
    }
}

// MARK: - Layout

/// TextKit 1 layout of a text box's text, shared by drawing (`TextObject.draw(in:)`) and the editor's text
/// view, which is set up the same way (no padding, no insets), so both put every glyph and list marker in
/// the same place.
final class TextLayout {
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer

    init(_ text: RichText, width: CGFloat) {
        storage = NSTextStorage(attributedString: text.attributedString())
        manager = NSLayoutManager()
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        Self.configure(container)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        trailing = text.paragraphs.last.map { $0.leadingStyle.attributes(in: TextParagraphFormat($0)) }
    }

    /// The attributes of a last paragraph that has no characters (see `RichText.init(_:trailing:)`).
    private let trailing: [NSAttributedString.Key: Any]?

    static func configure(_ container: NSTextContainer) {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
    }

    /// Indent per outline level, and the margin a list marker sits in, for text of `size`.
    static func indentStep(size: CGFloat) -> CGFloat {
        max(24, size * 1.5)
    }

    static func paragraphStyle(_ format: TextParagraphFormat, size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = format.alignment.nsAlignment
        let step = indentStep(size: size)
        let indent = CGFloat(format.indent) * step + (format.list == .none ? 0 : step)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacing = format.list == .none ? size * 0.2 : size * 0.15
        return style
    }

    /// How tall `text` is wrapped at `width`; at least one line.
    static func height(of text: RichText, width: CGFloat) -> CGFloat {
        cached(text, width: width).height
    }

    var height: CGFloat {
        Self.usedHeight(manager: manager, container: container, minimumLine: minimumLineHeight)
    }

    private var minimumLineHeight: CGFloat {
        ((trailing?[.font] as? UIFont) ?? TextStyle.standard.uiFont).lineHeight
    }

    static func usedHeight(manager: NSLayoutManager, container: NSTextContainer, minimumLine: CGFloat) -> CGFloat {
        manager.ensureLayout(for: container)
        // The used rect leaves out the empty line after a final newline, which the caret sits on.
        let used = manager.usedRect(for: container).union(manager.extraLineFragmentRect)
        return ceil(max(used.maxY, minimumLine))
    }

    func draw(at origin: CGPoint, in ctx: CGContext) {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        Self.drawMarkers(manager: manager, storage: storage, trailing: trailing, origin: origin, in: ctx)
    }

    func checkboxes() -> [(rect: CGRect, location: Int)] {
        Self.markerSlots(manager: manager, storage: storage, trailing: trailing).compactMap { slot in
            guard case .checkbox = slot.marker else { return nil }
            return (slot.box.insetBy(dx: -6, dy: -6), slot.location)
        }
    }

    // MARK: Markers

    /// One list paragraph's marker and where it goes, in the container's space.
    struct MarkerSlot {
        let marker: TextMarker
        /// The paragraph's first character.
        let location: Int
        /// The square the marker is centred in, on the paragraph's first line.
        let box: CGRect
        let baseline: CGFloat
        /// Where the margin the marker sits in ends: the start of the paragraph's text.
        let textStart: CGFloat
        let font: UIFont
        let color: UIColor
    }

    static func markerSlots(manager: NSLayoutManager, storage: NSTextStorage,
                            trailing: [NSAttributedString.Key: Any]?) -> [MarkerSlot] {
        let ns = storage.string as NSString
        // Each paragraph's first character and the attributes that lay it out; `extra` is a last paragraph
        // with no characters.
        struct Paragraph {
            let location: Int
            let attributes: [NSAttributedString.Key: Any]
            let extra: Bool
        }
        var paragraphs: [Paragraph] = []
        var start = 0
        while true {
            let newline = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            if start < ns.length {
                paragraphs.append(Paragraph(location: start, attributes: storage.attributes(at: start, effectiveRange: nil),
                                            extra: false))
            } else {
                // The last paragraph has no characters: the editor's typing attributes (or the model's) style it.
                let attributes = trailing ?? (ns.length > 0 ? storage.attributes(at: ns.length - 1, effectiveRange: nil) : [:])
                paragraphs.append(Paragraph(location: start, attributes: attributes, extra: true))
            }
            guard newline.location != NSNotFound else { break }
            start = newline.location + 1
        }
        let formats = paragraphs.map { TextParagraphFormat(attributes: $0.attributes) }
        let markers = TextMarker.markers(for: formats)
        var slots: [MarkerSlot] = []
        for (i, marker) in markers.enumerated() {
            guard let marker else { continue }
            let p = paragraphs[i]
            let line: CGRect
            let baseline: CGFloat
            let font = (p.attributes[.font] as? UIFont) ?? TextStyle.standard.uiFont
            if p.extra {
                line = manager.extraLineFragmentRect
                guard !line.isEmpty || ns.length == 0 else { continue }
                baseline = line.minY + font.ascender + max(0, (line.height - font.lineHeight) / 2)
            } else {
                let glyph = manager.glyphIndexForCharacter(at: p.location)
                guard glyph < manager.numberOfGlyphs else { continue }
                line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                baseline = line.minY + manager.location(forGlyphAt: glyph).y
            }
            let step = indentStep(size: font.pointSize)
            let x = CGFloat(formats[i].indent) * step
            let side = min(step, font.capHeight * 1.25 + 2)
            let centerY = baseline - font.capHeight / 2
            let box = CGRect(x: x + (step - side) / 2 - step * 0.1, y: centerY - side / 2, width: side, height: side)
            let color = (p.attributes[.foregroundColor] as? UIColor) ?? .black
            slots.append(MarkerSlot(marker: marker, location: p.location, box: box, baseline: baseline,
                                    textStart: x + step, font: font, color: color))
        }
        return slots
    }

    static func drawMarkers(manager: NSLayoutManager, storage: NSTextStorage, trailing: [NSAttributedString.Key: Any]?,
                            origin: CGPoint, in ctx: CGContext) {
        let slots = markerSlots(manager: manager, storage: storage, trailing: trailing)
        guard !slots.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: origin.x, y: origin.y)
        for slot in slots {
            draw(slot, in: ctx)
        }
    }

    private static func draw(_ slot: MarkerSlot, in ctx: CGContext) {
        let box = slot.box
        ctx.setFillColor(slot.color.cgColor)
        ctx.setStrokeColor(slot.color.cgColor)
        switch slot.marker {
        case let .bullet(level):
            let r = max(slot.font.xHeight * 0.22, 1.2)
            let dot = CGRect(x: box.midX - r, y: slot.baseline - slot.font.xHeight / 2 - r, width: 2 * r, height: 2 * r)
            switch level % 3 {
            case 0:
                ctx.fillEllipse(in: dot)
            case 1:
                ctx.setLineWidth(max(r * 0.45, 0.8))
                ctx.strokeEllipse(in: dot.insetBy(dx: r * 0.2, dy: r * 0.2))
            default:
                ctx.fill(dot.insetBy(dx: r * 0.1, dy: r * 0.1))
            }
        case let .number(n):
            let label = NSAttributedString(string: "\(n).", attributes: [
                .font: slot.font.withSize(slot.font.pointSize),
                .foregroundColor: slot.color
            ])
            let size = label.size()
            // Right-aligned against the text, on its baseline.
            let right = slot.textStart - slot.font.pointSize * 0.3
            label.draw(at: CGPoint(x: right - size.width, y: slot.baseline - slot.font.ascender))
        case let .checkbox(checked):
            let line = max(slot.font.pointSize / 14, 1)
            let square = box.insetBy(dx: line / 2, dy: line / 2)
            let path = UIBezierPath(roundedRect: square, cornerRadius: square.width * 0.22)
            ctx.setLineWidth(line)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
            if checked {
                ctx.setLineWidth(line * 1.3)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                let w = square.width
                ctx.move(to: CGPoint(x: square.minX + w * 0.24, y: square.minY + w * 0.52))
                ctx.addLine(to: CGPoint(x: square.minX + w * 0.43, y: square.minY + w * 0.72))
                ctx.addLine(to: CGPoint(x: square.minX + w * 0.78, y: square.minY + w * 0.30))
                ctx.strokePath()
            }
        }
    }

    // MARK: Cache

    private struct Key: Hashable {
        let text: RichText
        let width: CGFloat
    }

    @MainActor private static var cache: [Key: TextLayout] = [:]
    private static let pool = Pool()

    /// Layouts lent to other threads, one thread at a time each (a layout manager isn't safe to share): the
    /// object layer's tiles (NOT-109) draw a box once per tile it reaches, off the main thread.
    private final class Pool: @unchecked Sendable { // guarded by `lock`
        private let lock = NSLock()
        private var idle: [Key: [TextLayout]] = [:]
        private var count = 0

        func take(_ key: Key) -> TextLayout? {
            lock.withLock {
                guard let layout = idle[key]?.popLast() else { return nil }
                count -= 1
                return layout
            }
        }

        func put(_ layout: TextLayout, for key: Key) {
            lock.withLock {
                if count >= 64 {
                    idle.removeAll()
                    count = 0
                }
                idle[key, default: []].append(layout)
                count += 1
            }
        }
    }

    /// Runs `body` with a layout of `text` at `width`, kept for the next call on any thread.
    static func using<T>(_ text: RichText, width: CGFloat, _ body: (TextLayout) -> T) -> T {
        guard !Thread.isMainThread else { return body(cached(text, width: width)) }
        let key = Key(text: text, width: width)
        let layout = pool.take(key) ?? TextLayout(text, width: width)
        defer { pool.put(layout, for: key) }
        return body(layout)
    }

    /// A layout of `text` at `width`. On the main thread layouts are kept (text boxes are measured and hit
    /// often while editing); elsewhere each call lays out afresh (`using` keeps them).
    static func cached(_ text: RichText, width: CGFloat) -> TextLayout {
        guard Thread.isMainThread else { return TextLayout(text, width: width) }
        return MainActor.assumeIsolated {
            let key = Key(text: text, width: width)
            if let layout = cache[key] {
                return layout
            }
            if cache.count >= 64 {
                cache.removeAll()
            }
            let layout = TextLayout(text, width: width)
            cache[key] = layout
            return layout
        }
    }
}

// MARK: - Text for search and export

public extension PageObjectsFile {
    /// The plain text of the page's text boxes, in stacking order, one box per line: what search indexes.
    var text: String {
        TextObject.plainText(of: objects)
    }
}

public extension CanvasDocument {
    /// The plain text of the page's text boxes (see `PageObjectsFile.text`).
    var text: String {
        TextObject.plainText(of: objects)
    }
}

extension TextObject {
    static func plainText(of objects: [any PageObject]) -> String {
        objects.compactMap { ($0 as? TextObject)?.plainText }
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .joined(separator: "\n")
    }
}
