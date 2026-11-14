import UIKit

/// The text of a text box (`TextObject`): paragraphs of styled runs. It's plain data, so it can be saved,
/// compared, searched and drawn anywhere; the text box editor works on it as an `NSAttributedString`
/// (`attributedString()` and `init(_:trailing:)`), which round-trips exactly.
///
/// In the file it's `"paragraphs": [ { "runs": [ { "text": "…", "font": "sans", "size": 17, "color": "#1C1C1E",
/// "bold": true }, … ], "alignment": "left", "list": "checkbox", "checked": true, "indent": 1 }, … ]`.
/// Reading is lenient: an unknown font, list or alignment, or a size out of range, reads as the default,
/// so text is never lost.
public struct RichText: Hashable, Codable, Sendable {
    /// Never empty: empty text is one empty paragraph.
    public private(set) var paragraphs: [TextParagraph]

    public init(paragraphs: [TextParagraph]) {
        self.paragraphs = paragraphs.isEmpty ? [TextParagraph(style: .standard)] : paragraphs
    }

    /// Unformatted text in `style`, one paragraph per line.
    public init(_ plain: String, style: TextStyle = .standard) {
        self.init(paragraphs: plain.components(separatedBy: "\n").map { TextParagraph($0, style: style) })
    }

    /// The text without formatting, paragraphs joined by newlines: what search and export see.
    public var plainText: String {
        paragraphs.map(\.text).joined(separator: "\n")
    }

    /// True when there's nothing but whitespace.
    public var isBlank: Bool {
        plainText.allSatisfy(\.isWhitespace)
    }

    /// The text with trailing blank paragraphs removed (keeping at least one).
    public func trimmed() -> RichText {
        var paragraphs = paragraphs
        while paragraphs.count > 1, let last = paragraphs.last, last.text.allSatisfy(\.isWhitespace) {
            paragraphs.removeLast()
        }
        return RichText(paragraphs: paragraphs)
    }

    /// Every run in `color`.
    public func recolored(_ color: PenColor) -> RichText {
        var copy = self
        for p in copy.paragraphs.indices {
            for r in copy.paragraphs[p].runs.indices {
                copy.paragraphs[p].runs[r].style.color = color
            }
        }
        return copy
    }

    /// The style of the first run, for a text box's colour and the format bar.
    public var leadingStyle: TextStyle {
        paragraphs[0].runs[0].style
    }

    private enum CodingKeys: String, CodingKey {
        case paragraphs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(paragraphs: (try? c.decodeIfPresent([TextParagraph].self, forKey: .paragraphs)) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paragraphs, forKey: .paragraphs)
    }
}

/// One paragraph: its runs, and how it's laid out (alignment, list and indent).
public struct TextParagraph: Hashable, Codable, Sendable {
    /// Never empty: an empty paragraph is one empty run, which keeps its style.
    public var runs: [TextRun] {
        didSet {
            if runs.isEmpty {
                runs = [TextRun(text: "", style: oldValue.first?.style ?? .standard)]
            }
        }
    }

    public var alignment: TextAlignment
    public var list: TextList
    /// Whether a checklist item is ticked; ignored for other lists.
    public var checked: Bool
    /// Outline level, 0 … `TextParagraph.maxIndent`.
    public var indent: Int

    public static let maxIndent = 6

    public init(runs: [TextRun], alignment: TextAlignment = .left, list: TextList = .none, checked: Bool = false,
                indent: Int = 0) {
        self.runs = runs.isEmpty ? [TextRun(text: "", style: .standard)] : runs
        self.alignment = alignment
        self.list = list
        self.checked = checked
        self.indent = min(max(indent, 0), Self.maxIndent)
    }

    public init(_ text: String = "", style: TextStyle, alignment: TextAlignment = .left, list: TextList = .none,
                checked: Bool = false, indent: Int = 0) {
        self.init(runs: [TextRun(text: text, style: style)], alignment: alignment, list: list, checked: checked,
                  indent: indent)
    }

    public var text: String {
        runs.map(\.text).joined()
    }

    /// The paragraph's first style: its size sets the list marker's size.
    public var leadingStyle: TextStyle {
        runs[0].style
    }

    private enum CodingKeys: String, CodingKey {
        case runs, alignment, list, checked, indent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let runs = (try? c.decodeIfPresent([TextRun].self, forKey: .runs)) ?? []
        self.init(runs: runs,
                  alignment: (try? c.decodeIfPresent(TextAlignment.self, forKey: .alignment)) ?? .left,
                  list: (try? c.decodeIfPresent(TextList.self, forKey: .list)) ?? .none,
                  checked: (try? c.decodeIfPresent(Bool.self, forKey: .checked)) ?? false,
                  indent: (try? c.decodeIfPresent(Int.self, forKey: .indent)) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runs, forKey: .runs)
        if alignment != .left {
            try c.encode(alignment, forKey: .alignment)
        }
        if list != .none {
            try c.encode(list, forKey: .list)
        }
        if list == .checkbox, checked {
            try c.encode(true, forKey: .checked)
        }
        if indent != 0 {
            try c.encode(indent, forKey: .indent)
        }
    }
}

/// Text in one style. In the file, the style's keys sit beside `text`.
public struct TextRun: Hashable, Codable, Sendable {
    public var text: String
    public var style: TextStyle

    public init(text: String, style: TextStyle) {
        self.text = text
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        style = (try? TextStyle(from: decoder)) ?? .standard
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try style.encode(to: encoder)
    }
}

/// How a run of text looks.
public struct TextStyle: Hashable, Codable, Sendable {
    public var font: TextFont
    /// Page points.
    public var size: CGFloat {
        didSet { size = Self.clamped(size) }
    }

    public var color: PenColor
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public static let sizeRange: ClosedRange<CGFloat> = 6 ... 144
    /// The sizes the format bar offers.
    public static let presetSizes: [CGFloat] = [11, 13, 15, 17, 20, 24, 28, 34, 40, 48, 60, 72]
    public static let defaultColor = PenColor(rgb: 0x1C1C1E)
    public static let standard = TextStyle()

    public init(font: TextFont = .sans, size: CGFloat = 17, color: PenColor = TextStyle.defaultColor, bold: Bool = false,
                italic: Bool = false, underline: Bool = false) {
        self.font = font
        self.size = Self.clamped(size)
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    private static func clamped(_ size: CGFloat) -> CGFloat {
        size.isFinite ? min(max(size, sizeRange.lowerBound), sizeRange.upperBound) : 17
    }

    /// The font the style draws in. A face the design doesn't have (a rounded italic) falls back to the
    /// nearest one it does.
    public var uiFont: UIFont {
        var descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        if let designed = descriptor.withDesign(font.design) {
            descriptor = designed
        }
        var traits = UIFontDescriptor.SymbolicTraits()
        if bold {
            traits.insert(.traitBold)
        }
        if italic {
            traits.insert(.traitItalic)
        }
        if !traits.isEmpty {
            descriptor = descriptor.withSymbolicTraits(traits)
                ?? descriptor.withSymbolicTraits(traits.subtracting(.traitItalic))
                ?? descriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private enum CodingKeys: String, CodingKey {
        case font, size, color, bold, italic, underline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 17
        self.init(font: (try? c.decodeIfPresent(TextFont.self, forKey: .font)) ?? .sans,
                  size: CGFloat(size),
                  color: (try? c.decodeIfPresent(PenColor.self, forKey: .color)) ?? Self.defaultColor,
                  bold: (try? c.decodeIfPresent(Bool.self, forKey: .bold)) ?? false,
                  italic: (try? c.decodeIfPresent(Bool.self, forKey: .italic)) ?? false,
                  underline: (try? c.decodeIfPresent(Bool.self, forKey: .underline)) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(font, forKey: .font)
        try c.encode(Double(size), forKey: .size)
        try c.encode(color, forKey: .color)
        if bold {
            try c.encode(true, forKey: .bold)
        }
        if italic {
            try c.encode(true, forKey: .italic)
        }
        if underline {
            try c.encode(true, forKey: .underline)
        }
    }
}

/// The typefaces a text box offers: the system font's four designs.
public enum TextFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case sans, serif, rounded, mono

    public var id: String {
        rawValue
    }

    var design: UIFontDescriptor.SystemDesign {
        switch self {
        case .sans: .default
        case .serif: .serif
        case .rounded: .rounded
        case .mono: .monospaced
        }
    }

    public var title: String {
        switch self {
        case .sans: "Sans Serif"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .mono: "Monospaced"
        }
    }
}

public enum TextAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, center, right, justified

    public var id: String {
        rawValue
    }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    init(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center: self = .center
        case .right: self = .right
        case .justified: self = .justified
        default: self = .left
        }
    }
}

/// A paragraph's list: none, a bullet, a number or a checkbox in the margin before it.
public enum TextList: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, bullet, numbered, checkbox

    public var id: String {
        rawValue
    }
}

// MARK: - List markers

/// What's drawn in a list paragraph's margin.
enum TextMarker: Equatable {
    case bullet(level: Int)
    case number(Int)
    case checkbox(checked: Bool)

    /// Each paragraph's marker, nil for paragraphs that aren't in a list. Numbers count up through
    /// consecutive numbered paragraphs at one level; a deeper level starts again at 1 under each item, and
    /// anything else at the same level or shallower (a plain paragraph, a bullet) ends the numbering.
    static func markers(for paragraphs: [TextParagraphFormat]) -> [TextMarker?] {
        var counters = [Int](repeating: 0, count: TextParagraph.maxIndent + 1)
        return paragraphs.map { p in
            let level = min(max(p.indent, 0), TextParagraph.maxIndent)
            for deeper in (level + 1) ..< counters.count {
                counters[deeper] = 0
            }
            switch p.list {
            case .none:
                counters[level] = 0
                return nil
            case .bullet:
                counters[level] = 0
                return .bullet(level: level)
            case .checkbox:
                counters[level] = 0
                return .checkbox(checked: p.checked)
            case .numbered:
                counters[level] += 1
                return .number(counters[level])
            }
        }
    }
}

// MARK: - Attributed strings

extension NSAttributedString.Key {
    /// The run's `TextFont` (raw value); the font's own traits say bold and italic.
    static let inkFont = NSAttributedString.Key("InkKit.font")
    /// The paragraph's `TextList` (raw value).
    static let inkList = NSAttributedString.Key("InkKit.list")
    /// Whether a checklist paragraph is ticked.
    static let inkChecked = NSAttributedString.Key("InkKit.checked")
    /// The paragraph's outline level.
    static let inkIndent = NSAttributedString.Key("InkKit.indent")
}

/// A paragraph's layout without its runs, as read from and written to attributes.
struct TextParagraphFormat: Equatable {
    var alignment: TextAlignment = .left
    var list: TextList = .none
    var checked = false
    var indent = 0

    init(alignment: TextAlignment = .left, list: TextList = .none, checked: Bool = false, indent: Int = 0) {
        self.alignment = alignment
        self.list = list
        self.checked = checked
        self.indent = min(max(indent, 0), TextParagraph.maxIndent)
    }

    init(_ paragraph: TextParagraph) {
        self.init(alignment: paragraph.alignment, list: paragraph.list, checked: paragraph.checked,
                  indent: paragraph.indent)
    }

    init(attributes: [NSAttributedString.Key: Any]) {
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        self.init(alignment: style.map { TextAlignment($0.alignment) } ?? .left,
                  list: (attributes[.inkList] as? String).flatMap(TextList.init(rawValue:)) ?? .none,
                  checked: attributes[.inkChecked] as? Bool ?? false,
                  indent: attributes[.inkIndent] as? Int ?? 0)
    }
}

extension TextStyle {
    /// Reads a run's style back from its attributes. The font gives the size, bold and italic (so the
    /// system's Bold and Italic commands are kept), `inkFont` the typeface.
    init(attributes: [NSAttributedString.Key: Any]) {
        let font = attributes[.font] as? UIFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let face = (attributes[.inkFont] as? String).flatMap(TextFont.init(rawValue:))
            ?? (traits.contains(.traitMonoSpace) ? .mono : .sans)
        var color = TextStyle.defaultColor
        if let ui = attributes[.foregroundColor] as? UIColor, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = ui.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
           let c = converted.components, c.count >= 3 {
            color = PenColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
        }
        self.init(font: face, size: font?.pointSize ?? 17, color: color, bold: traits.contains(.traitBold),
                  italic: traits.contains(.traitItalic),
                  underline: (attributes[.underlineStyle] as? Int ?? 0) != 0)
    }

    /// The attributes a run in this style has, in a paragraph laid out as `format`.
    func attributes(in format: TextParagraphFormat, paragraphSize: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: uiFont,
            .foregroundColor: UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1),
            .paragraphStyle: TextLayout.paragraphStyle(format, size: paragraphSize ?? size),
            .inkFont: font.rawValue,
            .inkList: format.list.rawValue,
            .inkChecked: format.checked,
            .inkIndent: format.indent
        ]
        if underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }
}

extension RichText {
    /// The text as an attributed string for TextKit. Each paragraph but the last ends in "\n", which carries
    /// the paragraph's last style; an empty paragraph is just its "\n".
    func attributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, paragraph) in paragraphs.enumerated() {
            let format = TextParagraphFormat(paragraph)
            let size = paragraph.leadingStyle.size
            for run in paragraph.runs where !run.text.isEmpty {
                result.append(NSAttributedString(string: run.text, attributes: run.style.attributes(in: format, paragraphSize: size)))
            }
            if i < paragraphs.count - 1 {
                let style = paragraph.runs.last?.style ?? paragraph.leadingStyle
                result.append(NSAttributedString(string: "\n", attributes: style.attributes(in: format, paragraphSize: size)))
            }
        }
        return result
    }

    /// Reads text back from an attributed string (the editor's). A paragraph's layout is its first
    /// character's; `trailing` (the editor's typing attributes) styles a last paragraph with no characters.
    init(_ string: NSAttributedString, trailing: [NSAttributedString.Key: Any]? = nil) {
        let ns = string.string as NSString
        var paragraphs: [TextParagraph] = []
        var start = 0
        var lastAttributes = trailing ?? TextStyle.standard.attributes(in: TextParagraphFormat())
        while true {
            let newline = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let body = NSRange(location: start, length: end - start)
            let hasTerminator = newline.location != NSNotFound
            let leading: [NSAttributedString.Key: Any] = if body.length > 0 || hasTerminator {
                string.attributes(at: start, effectiveRange: nil)
            } else {
                trailing ?? lastAttributes
            }
            var runs: [TextRun] = []
            if body.length > 0 {
                string.enumerateAttributes(in: body) { attributes, range, _ in
                    let style = TextStyle(attributes: attributes)
                    let text = ns.substring(with: range)
                    if let last = runs.last, last.style == style {
                        runs[runs.count - 1].text += text
                    } else {
                        runs.append(TextRun(text: text, style: style))
                    }
                }
            } else {
                runs = [TextRun(text: "", style: TextStyle(attributes: leading))]
            }
            let format = TextParagraphFormat(attributes: leading)
            paragraphs.append(TextParagraph(runs: runs, alignment: format.alignment, list: format.list,
                                            checked: format.checked, indent: format.indent))
            lastAttributes = leading
            guard hasTerminator else { break }
            start = end + 1
        }
        self.init(paragraphs: paragraphs)
    }
}
