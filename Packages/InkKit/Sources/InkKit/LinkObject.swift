import CoreGraphics
import Foundation

/// Where a link goes: a web address, a page of the same note, or another note (optionally one of its pages).
///
/// In a page's objects file it's one JSON object with one of these shapes:
///
/// ```json
/// { "url": "https://example.com" }
/// { "page": "<page id>" }
/// { "note": "<note id>" }                       // the note, at whatever page it was on
/// { "note": "<note id>", "page": "<page id>" }  // a page of another note
/// ```
///
/// InkKit follows `.url` and `.page` itself. It doesn't know about notes: `.note` is handed to the host
/// (`InkCanvasEditor`'s `links`), which opens the note.
public enum LinkTarget: Hashable, Sendable {
    case url(URL)
    case page(UUID)
    case note(UUID, page: UUID?)

    /// The page a link inside the note goes to; nil for web and other-note links.
    public var pageID: UUID? {
        if case let .page(id) = self {
            return id
        }
        return nil
    }

    /// A web address typed by hand: `example.com` becomes `https://example.com`. Nil for text that isn't
    /// an http(s) or mailto address with somewhere to go.
    public static func web(_ text: String) -> LinkTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let hasScheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        guard let url = URL(string: hasScheme ? trimmed : "https://" + trimmed),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        case "mailto":
            guard url.absoluteString.count > "mailto:".count else { return nil }
        default:
            return nil
        }
        return .url(url)
    }
}

extension LinkTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case url, page, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let note = try c.decodeIfPresent(UUID.self, forKey: .note) {
            self = try .note(note, page: c.decodeIfPresent(UUID.self, forKey: .page))
        } else if let page = try c.decodeIfPresent(UUID.self, forKey: .page) {
            self = .page(page)
        } else if let text = try c.decodeIfPresent(String.self, forKey: .url), let url = URL(string: text) {
            self = .url(url)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "a link goes to a url, a page or a note"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .url(url):
            try c.encode(url.absoluteString, forKey: .url)
        case let .page(page):
            try c.encode(page, forKey: .page)
        case let .note(note, page):
            try c.encode(note, forKey: .note)
            try c.encodeIfPresent(page, forKey: .page)
        }
    }
}

/// A link on the page: a rectangle over some ink, a text box, a picture (any selection) that goes
/// somewhere when it's tapped (`LinkTarget`).
///
/// **Adding.** The lasso selection's menu has Add Link…, which puts a link over the selection's bounds.
/// A link is an object of its own rather than part of what it covers, so ink and objects of every kind can
/// be linked the same way; the lasso picks it up with what it covers, so they move together.
///
/// **Following.** A tap on it with the pen, pencil, highlighter, shape tool or laser follows it (tape over a
/// link is revealed first); the lasso selects it, to change its target or remove it. Under the ink like other
/// objects, it's drawn as a faint tint of its colour with a dotted underline, so writing over it stays legible.
///
/// File kind `"link"`; its own fields are `target` (see `LinkTarget`), `title` (what it's called in menus and
/// to VoiceOver, optional) and `color`. A target this version can't read (from a newer app) is kept as it was
/// read and written back unchanged; such a link does nothing when tapped.
public struct LinkObject: PageObject, Equatable {
    public static let kind = "link"

    public let id: UUID
    public var frame: CGRect
    public var transform: CGAffineTransform
    public var zIndex: Int
    /// Where it goes; nil when the file's target couldn't be read.
    public var target: LinkTarget? {
        didSet { unreadTarget = nil }
    }

    /// A short description of where it goes, e.g. "Page 3" or "example.com".
    public var title: String?
    public var color: PenColor
    /// The target as read, when it couldn't be (kept so it's written back as it was).
    private var unreadTarget: JSONValue?

    /// Links are this colour unless the theme says otherwise (`InkTheme.link`).
    public static let defaultColor = PenColor(rgb: 0x3345D9)
    /// How far a link reaches past what it was made over, in page points, so it's easy to tap.
    public static let padding: CGFloat = 4

    public init(id: UUID = UUID(), frame: CGRect, transform: CGAffineTransform = .identity, zIndex: Int = 0,
                target: LinkTarget, title: String? = nil, color: PenColor = LinkObject.defaultColor) {
        self.id = id
        self.frame = frame
        self.transform = transform
        self.zIndex = zIndex
        self.target = target
        self.title = title
        self.color = color
    }

    /// A link over `bounds` (page space), padded so it's comfortable to tap.
    public init(covering bounds: CGRect, target: LinkTarget, title: String? = nil,
                color: PenColor = LinkObject.defaultColor) {
        let padded = bounds.standardized.insetBy(dx: -Self.padding, dy: -Self.padding)
        self.init(frame: padded, target: target, title: title, color: color)
    }

    public func recolored(_ color: PenColor) -> LinkObject {
        var copy = self
        copy.color = color
        return copy
    }

    // MARK: Drawing

    public func draw(in ctx: CGContext) {
        let r = frame
        guard r.width > 0, r.height > 0 else { return }
        let ink = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        let line = max(0.75, min(r.height / 24, 1.5))
        let radius = min(4, r.height / 4, r.width / 4)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(ink.copy(alpha: 0.08) ?? ink)
        ctx.fillPath()
        // A dotted underline along the bottom: the page's "this is a link".
        ctx.setStrokeColor(ink.copy(alpha: 0.75) ?? ink)
        ctx.setLineWidth(line)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [0.01, 3 * line])
        let y = r.maxY - line
        ctx.move(to: CGPoint(x: r.minX + radius, y: y))
        ctx.addLine(to: CGPoint(x: r.maxX - radius, y: y))
        ctx.strokePath()
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case target, title, color
    }

    public init(from decoder: Decoder) throws {
        let placement = try PageObjectPlacement(from: decoder)
        id = placement.id
        frame = placement.frame
        transform = placement.transform
        zIndex = placement.zIndex
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let target = try? c.decode(LinkTarget.self, forKey: .target) {
            self.target = target
        } else {
            target = nil
            unreadTarget = try? c.decodeIfPresent(JSONValue.self, forKey: .target)
        }
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        color = (try? c.decodeIfPresent(PenColor.self, forKey: .color)) ?? Self.defaultColor
    }

    public func encode(to encoder: Encoder) throws {
        try PageObjectPlacement(of: self).encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let target {
            try c.encode(target, forKey: .target)
        } else if let unreadTarget {
            try c.encode(unreadTarget, forKey: .target)
        }
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(color, forKey: .color)
    }
}

// MARK: - Links on a page

public extension CanvasDocument {
    /// The page's links, lowest first.
    var links: [LinkObject] {
        objects.compactMap { $0 as? LinkObject }
    }

    /// The topmost link under `point` (page space), within `tolerance` page points.
    func link(at point: CGPoint, tolerance: CGFloat = 0) -> LinkObject? {
        objects.reversed().lazy.compactMap { $0 as? LinkObject }.first { $0.contains(point, tolerance: tolerance) }
    }

    /// Puts a link to `target` over `bounds` (page space) on top of the page's objects, as one undoable edit,
    /// and returns it.
    @discardableResult
    func addLink(to target: LinkTarget, covering bounds: CGRect, title: String? = nil,
                 color: PenColor = LinkObject.defaultColor) -> LinkObject {
        let link = LinkObject(covering: bounds, target: target, title: title, color: color)
        addObject(link)
        return object(id: link.id) as? LinkObject ?? link
    }

    /// Points the link with this id somewhere else, as one undoable edit. Returns the link as it is now, or
    /// nil if there's no link with that id.
    @discardableResult
    func setLinkTarget(id: UUID, to target: LinkTarget, title: String?) -> LinkObject? {
        guard let link = object(id: id) as? LinkObject else { return nil }
        var changed = link
        changed.target = target
        changed.title = title
        guard changed != link else { return link }
        replaceObjects(before: [link], after: [changed])
        return changed
    }
}
