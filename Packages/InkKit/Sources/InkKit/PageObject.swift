import CoreGraphics
import Foundation

/// Something on a page that isn't ink: a shape, a text box, an image or tape (Architecture §5).
///
/// Every object has the same placement: a `frame` in its own space, a `transform` that puts that frame
/// on the page, and a `zIndex` among the page's objects. The lasso, tap-to-select, the selection handles
/// and undo work on that placement alone, so a new kind of object only has to draw itself and say how it
/// encodes its own fields.
///
/// **Layers.** A page draws its background (paper and template), then its objects in `zIndex` order,
/// then its ink, then the selection overlay. Objects are always under the ink, so handwriting over an
/// image stays on top of it, and the pixel eraser never erases an object.
///
/// **Storage.** A page's objects are kept in `pages/<page id>.json` beside its `.ink` file
/// (`PageObjectsFile`). Each object is one JSON object with a `kind` and the shared placement keys
/// (`id`, `frame`, `transform`, `zIndex`; see `PageObjectPlacement`) next to its own fields.
public protocol PageObject: Codable, Sendable {
    /// Names the type in `pages/<page id>.json`, e.g. `"placeholder"`. Never changes once shipped.
    static var kind: String { get }

    var id: UUID { get }
    /// The object's own rectangle, before `transform`.
    var frame: CGRect { get set }
    /// Maps the object's own space onto the page (canvas space). Identity puts `frame` on the page as it is.
    var transform: CGAffineTransform { get set }
    /// Stacking order among the page's objects, lowest first. Every object is under the page's ink.
    var zIndex: Int { get set }

    /// Draws the object in its own space; the caller has already applied `transform`.
    func draw(in ctx: CGContext)

    /// The object drawn in `color`, for the lasso's Color menu. The default keeps the object as it is,
    /// for kinds that have no colour of their own (an image).
    func recolored(_ color: PenColor) -> Self

    /// The object with `t` applied after its own transform: moved, scaled or rotated on the page. The default
    /// concatenates `t` onto `transform`; a text box keeps its letters' size and rewraps instead.
    func applying(_ t: CGAffineTransform) -> Self

    /// Whether `point` (page space) is on the object, or within `tolerance` page points of it, for selecting
    /// it with a tap. The default is its frame; a picture with a freehand crop is only its outline.
    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool
}

public extension PageObject {
    /// The kind of this object, as written in the file.
    var kind: String {
        Self.kind
    }

    /// The four corners of `frame` on the page, clockwise from the top-left.
    var corners: [CGPoint] {
        let f = frame
        return [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY)].map { $0.applying(transform) }
    }

    /// The smallest page-space rectangle holding the object.
    var bounds: CGRect {
        frame.applying(transform)
    }

    /// Whether `point` (page space) is on the object, or within `tolerance` page points of its frame.
    func contains(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        let det = transform.a * transform.d - transform.b * transform.c
        guard abs(det) > 1e-12 else { return false }
        // Tolerance is measured on the page; in the object's own space it's divided by the transform's scale.
        let scale = max(sqrt(abs(det)), 1e-6)
        return frame.insetBy(dx: -tolerance / scale, dy: -tolerance / scale)
            .contains(point.applying(transform.inverted()))
    }

    func applying(_ t: CGAffineTransform) -> Self {
        var copy = self
        copy.transform = transform.concatenating(t)
        return copy
    }

    func recolored(_: PenColor) -> Self {
        self
    }
}

// MARK: - Placement

/// The keys every object shares in the file, flattened into the object's own JSON object:
///
/// ```json
/// { "kind": "placeholder", "id": "…", "frame": { "x": 0, "y": 0, "width": 100, "height": 50 },
///   "transform": [1, 0, 0, 1, 0, 0], "zIndex": 0, … }
/// ```
///
/// `transform` is `[a, b, c, d, tx, ty]` (`CGAffineTransform`'s order). A missing transform is the
/// identity and a missing `zIndex` is 0; a frame or transform that isn't finite, a negative size or a
/// transform that can't be inverted is `corrupt`.
public struct PageObjectPlacement: Equatable, Sendable {
    public var id: UUID
    public var frame: CGRect
    public var transform: CGAffineTransform
    public var zIndex: Int

    public init(id: UUID = UUID(), frame: CGRect, transform: CGAffineTransform = .identity, zIndex: Int = 0) {
        self.id = id
        self.frame = frame
        self.transform = transform
        self.zIndex = zIndex
    }

    public init(of object: some PageObject) {
        self.init(id: object.id, frame: object.frame, transform: object.transform, zIndex: object.zIndex)
    }

    enum CodingKeys: String, CodingKey {
        case id, frame, transform, zIndex
    }

    private struct Frame: Codable {
        var x, y, width, height: Double
    }

    /// Reads the shared keys from an object's JSON (`decoder` is the object's own decoder).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let f = try c.decode(Frame.self, forKey: .frame)
        frame = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
        if let t = try c.decodeIfPresent([Double].self, forKey: .transform) {
            guard t.count == 6 else {
                throw DecodingError.dataCorruptedError(forKey: .transform, in: c,
                                                       debugDescription: "a transform has six numbers")
            }
            transform = CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5])
        } else {
            transform = .identity
        }
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .frame, in: c,
                                                   debugDescription: "frame or transform out of range")
        }
    }

    /// Writes the shared keys into an object's JSON (`encoder` is the object's own encoder).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(Frame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), forKey: .frame)
        try c.encode([transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].map(Double.init),
                     forKey: .transform)
        try c.encode(zIndex, forKey: .zIndex)
    }

    /// Finite numbers, a frame no smaller than nothing, and a transform that can be undone.
    var isValid: Bool {
        let numbers = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                       transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        guard numbers.allSatisfy(\.isFinite), frame.size.width >= 0, frame.size.height >= 0 else { return false }
        return abs(transform.a * transform.d - transform.b * transform.c) > 1e-12
    }
}

// MARK: - Placeholder

/// A plain rectangle with a cross through it: the test object that exercises the object layer (adding,
/// moving, resizing, rotating, undo and persistence) until real shapes, text, images and tape arrive.
///
/// File kind `"placeholder"`; its own field is `color` (`"#RRGGBB"`). Its outline and cross are drawn in
/// its own space, so they thicken and thin with it as it's resized, like a drawn shape.
public struct PlaceholderObject: PageObject, Equatable {
    public static let kind = "placeholder"

    public let id: UUID
    public var frame: CGRect
    public var transform: CGAffineTransform
    public var zIndex: Int
    /// Outline and cross; the fill is a light tint of it.
    public var color: PenColor

    public init(id: UUID = UUID(), frame: CGRect, transform: CGAffineTransform = .identity, zIndex: Int = 0,
                color: PenColor) {
        self.id = id
        self.frame = frame
        self.transform = transform
        self.zIndex = zIndex
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case color
    }

    public init(from decoder: Decoder) throws {
        let placement = try PageObjectPlacement(from: decoder)
        id = placement.id
        frame = placement.frame
        transform = placement.transform
        zIndex = placement.zIndex
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Lenient like brushes: a colour that can't be read is the default ink rather than a lost object.
        color = (try? c.decodeIfPresent(PenColor.self, forKey: .color)) ?? PenColor(rgb: 0x1F2937)
    }

    public func encode(to encoder: Encoder) throws {
        try PageObjectPlacement(of: self).encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
    }

    public func recolored(_ color: PenColor) -> PlaceholderObject {
        var copy = self
        copy.color = color
        return copy
    }

    public func draw(in ctx: CGContext) {
        let ink = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        let r = frame
        let line = min(2, max(0.5, min(r.width, r.height) / 40))
        ctx.saveGState()
        ctx.setFillColor(ink.copy(alpha: 0.12) ?? ink)
        ctx.fill(r)
        ctx.setStrokeColor(ink.copy(alpha: 0.45) ?? ink)
        ctx.setLineWidth(line / 2)
        ctx.move(to: CGPoint(x: r.minX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.move(to: CGPoint(x: r.maxX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        ctx.strokePath()
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(line)
        ctx.stroke(r.insetBy(dx: line / 2, dy: line / 2))
        ctx.restoreGState()
    }
}

// MARK: - Objects of unknown kinds

/// An object of a kind this version doesn't know, written by a newer app. It's kept exactly as read,
/// in its place in the stacking order, and written back when the page is saved; it isn't drawn and
/// can't be selected, so nothing can change it.
struct UnknownPageObject: PageObject, Equatable {
    static let kind = "unknown"

    let id: UUID
    var frame: CGRect
    var transform: CGAffineTransform
    var zIndex: Int
    /// The object's JSON as read, `kind` included.
    let json: JSONValue

    init(from decoder: Decoder) throws {
        let placement = try PageObjectPlacement(from: decoder)
        id = placement.id
        frame = placement.frame
        transform = placement.transform
        zIndex = placement.zIndex
        json = try JSONValue(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    func draw(in _: CGContext) {}
}

/// Any JSON value, for keeping objects of unknown kinds as they were.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: Key.self) {
            var object: [String: JSONValue] = [:]
            for key in c.allKeys {
                object[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
        } else if var c = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !c.isAtEnd {
                try array.append(c.decode(JSONValue.self))
            }
            self = .array(array)
        } else {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else {
                self = try .string(c.decode(String.self))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(object):
            var c = encoder.container(keyedBy: Key.self)
            for (key, value) in object {
                try c.encode(value, forKey: Key(stringValue: key))
            }
        case let .array(array):
            var c = encoder.unkeyedContainer()
            for value in array {
                try c.encode(value)
            }
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case let .bool(b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case let .number(n):
            var c = encoder.singleValueContainer()
            try c.encode(n)
        case let .string(s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        }
    }
}

// MARK: - Kinds

enum PageObjectKinds {
    /// Every kind this version reads. Add new object types here.
    static let known: [String: any PageObject.Type] = [
        PlaceholderObject.kind: PlaceholderObject.self,
        ShapeObject.kind: ShapeObject.self,
        TextObject.kind: TextObject.self,
        ImageObject.kind: ImageObject.self
    ]

    /// Whether objects of this type can be seen and selected (objects of unknown kinds can't).
    static func isSelectable(_ object: any PageObject) -> Bool {
        !(object is UnknownPageObject)
    }
}
