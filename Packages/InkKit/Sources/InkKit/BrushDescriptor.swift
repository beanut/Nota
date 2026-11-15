import CoreGraphics
import Foundation

/// Everything that decides how a stroke looks, as plain data (Architecture §4).
///
/// Built-in brushes are bundled descriptors (`BuiltInBrushes.swift`), so a built-in pen and one a user or
/// a model made go through the same code. A stroke keeps a snapshot of its
/// descriptor, so changing a brush later never restyles ink already on the page, and each page's `.ink`
/// file stores every distinct descriptor once in its brush table.
///
/// **Ranges.** Every parameter has a documented legal range. `clamped()` pulls each one into it (and
/// replaces non-finite numbers with the pen's value), and decoding always clamps: missing keys take the
/// pen's values and unknown enum cases fall back to the default, so no JSON, however odd, decodes to a
/// brush the renderer can't draw.
///
/// **Render path.** A descriptor with `spacing == 0` and no bristle texture draws on the **hull path**:
/// the nib swept continuously along the stroke, as pens always have. Otherwise it draws on the **stamp
/// path**: separate nib stamps every `spacing` nib widths, each moved by `jitter`, for textured brushes.
///
/// **Raster brushes.** A `wax` texture (the crayon) is drawn by the GPU rather than filled as paths: its
/// stamps are rasterized with Metal into a pressure field, and wax is laid on a paper tooth fixed to the page
/// (`WaxRenderer`). Without Metal it falls back to the grain pattern, like a pencil.
public struct BrushDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Shown in the brush picker. At most `maxNameLength` characters.
    public var name: String
    /// The nib's cross-section.
    public var tip: TipShape
    /// Nib width in canvas points: `lowerBound` at no pressure, `upperBound` at full pressure.
    /// Upper bound 0.05…1000; lower bound 0…upper bound.
    public var size: ClosedRange<CGFloat>
    /// Pressure → width, mapped across `size`. With `amount` 0 pressure is ignored and the width is `size.upperBound`.
    public var pressure: ResponseCurve
    /// Pressure → opacity (multiplies `opacity`). The default, `amount` 0, ignores pressure.
    public var pressureOpacity: ResponseCurve
    /// Tilt shading: how altitude widens and lightens the nib; the nib follows the Pencil's azimuth.
    public var tilt: TiltResponse
    /// Speed → width. The input is how slowly the nib moves (1 at rest, 0 at `ResponseCurve.fastSpeed`
    /// and over), so `amount` is how much a fast stroke thins. The default, 0, ignores speed.
    public var velocity: ResponseCurve
    /// Narrowing at the stroke's start and end.
    public var taper: Taper
    /// Stabiliser strength, 0…0.95: how much each new sample is pulled toward the stroke so far.
    /// 0 keeps the samples as they are.
    public var smoothing: CGFloat
    /// Procedural texture, drawn into the fill. Never a bitmap: parameters and a seed.
    public var texture: Texture
    /// Distance between stamps in nib widths: 0 (continuous, the hull path) or 0.05…4 (the stamp path).
    public var spacing: CGFloat
    /// Random variation per stamp, on the stamp path.
    public var jitter: Jitter
    /// A dash pattern along the stroke. The default, `.none`, is solid; a pattern draws on the stamp path.
    public var dash: Dash
    /// Ink pooling, 0…1: slow movement lays down more and wider ink, fast movement less.
    public var wetness: CGFloat
    /// How the stroke composites onto the page.
    public var blend: BlendMode
    /// Overall opacity, 0.02…1.
    public var opacity: CGFloat

    public init(id: UUID = UUID(), name: String, tip: TipShape = .round, size: ClosedRange<CGFloat>,
                pressure: ResponseCurve = .standardPressure, pressureOpacity: ResponseCurve = .none,
                tilt: TiltResponse = .standard, velocity: ResponseCurve = .none, taper: Taper = .none,
                smoothing: CGFloat = 0, texture: Texture = .none, spacing: CGFloat = 0, jitter: Jitter = .none,
                dash: Dash = .none, wetness: CGFloat = 0, blend: BlendMode = .normal, opacity: CGFloat = 1) {
        self.id = id
        self.name = name
        self.tip = tip
        self.size = size
        self.pressure = pressure
        self.pressureOpacity = pressureOpacity
        self.tilt = tilt
        self.velocity = velocity
        self.taper = taper
        self.smoothing = smoothing
        self.texture = texture
        self.spacing = spacing
        self.jitter = jitter
        self.dash = dash
        self.wetness = wetness
        self.blend = blend
        self.opacity = opacity
    }

    // MARK: Parameter types

    /// The nib's cross-section.
    public enum TipShape: Hashable, Sendable {
        /// A circle (an ellipse along the azimuth when tilted).
        case round
        /// A flat nib held at a fixed angle, like a calligraphy pen. `aspect` 0.05…1 is minor / major
        /// axis; `angle` is the major axis's direction in radians (normalised to −π…π).
        case ellipse(aspect: CGFloat, angle: CGFloat)
    }

    /// A response curve from an input in 0…1 to a multiplier: `1 − amount + amount × input^exponent`.
    public struct ResponseCurve: Codable, Hashable, Sendable {
        /// 0…1: how much the input matters. 0 ignores it (always 1); 1 uses the whole curve.
        public var amount: CGFloat
        /// 0.1…5: the curve's shape. Below 1 responds early (soft), above 1 late (firm).
        public var exponent: CGFloat

        public init(amount: CGFloat, exponent: CGFloat = 1) {
            self.amount = amount
            self.exponent = exponent
        }

        /// The input is ignored.
        public static let none = ResponseCurve(amount: 0, exponent: 1)
        /// The pen's pressure response.
        public static let standardPressure = ResponseCurve(amount: 1, exponent: 0.6)
        /// Speed, in canvas points per second, at and above which `velocity` has its full effect.
        public static let fastSpeed: CGFloat = 1500

        var isActive: Bool {
            amount > 0
        }

        /// The multiplier for `input`, which is clamped to 0…1.
        public func value(_ input: CGFloat) -> CGFloat {
            guard amount > 0 else { return 1 }
            let shaped = pow(min(max(input, 0), 1), exponent)
            return amount == 1 ? shaped : 1 - amount + amount * shaped
        }
    }

    /// How tilt (altitude) changes the nib. Shading starts below `startAltitude` and is full at
    /// `fullAltitude`, eased in between; at full tilt the nib is `1 + length` times as long along the
    /// azimuth, `1 + breadth` times as wide across it, and `1 − opacityLoss` as opaque. The contact patch
    /// moves `contactShift` of the extra length toward the barrel.
    public struct TiltResponse: Codable, Hashable, Sendable {
        public var enabled: Bool
        /// Degrees, 1…89.
        public var startAltitude: CGFloat
        /// Degrees, 0…`startAltitude − 1`.
        public var fullAltitude: CGFloat
        /// 0…8.
        public var length: CGFloat
        /// 0…4.
        public var breadth: CGFloat
        /// 0…1.
        public var opacityLoss: CGFloat
        /// 0…1.
        public var contactShift: CGFloat

        public init(enabled: Bool = true, startAltitude: CGFloat = 60, fullAltitude: CGFloat = 15,
                    length: CGFloat = 3.5, breadth: CGFloat = 0.6, opacityLoss: CGFloat = 0.6,
                    contactShift: CGFloat = 0.35) {
            self.enabled = enabled
            self.startAltitude = startAltitude
            self.fullAltitude = fullAltitude
            self.length = length
            self.breadth = breadth
            self.opacityLoss = opacityLoss
            self.contactShift = contactShift
        }

        /// The pencil-like shading every built-in ink brush uses.
        public static let standard = TiltResponse()
        public static let off = TiltResponse(enabled: false)
    }

    /// Narrowing over the first `startLength` and last `endLength` canvas points of a stroke, from
    /// `minimumScale` of the width at the very end to the full width. The end taper is applied when the
    /// stroke ends (the live stroke can't know where it will stop).
    public struct Taper: Codable, Hashable, Sendable {
        /// 0…500 canvas points.
        public var startLength: CGFloat
        /// 0…500 canvas points.
        public var endLength: CGFloat
        /// 0…1: width at the very start or end, as a fraction of the untapered width.
        public var minimumScale: CGFloat

        public init(startLength: CGFloat, endLength: CGFloat, minimumScale: CGFloat = 0.1) {
            self.startLength = startLength
            self.endLength = endLength
            self.minimumScale = minimumScale
        }

        public static let none = Taper(startLength: 0, endLength: 0)

        var isActive: Bool {
            (startLength > 0 || endLength > 0) && minimumScale < 1
        }
    }

    /// Procedural texture.
    public enum Texture: Hashable, Sendable {
        case none
        /// Paper tooth: graphite catches on the paper's grain. `scale` 0.25…8 (1 is the pencil's 64-point
        /// tile), `contrast` 0…1 (how much of the tooth shows), `seed` picks the grain.
        case grain(scale: CGFloat, contrast: CGFloat, seed: UInt32)
        /// A dry brush: each stamp is `count` (1…64) bristle dots, spread over `spread` (0.1…2) of the nib.
        /// Always drawn on the stamp path.
        case bristle(count: Int, spread: CGFloat)
        /// Wax on paper tooth, rasterized on the GPU (a raster brush, see `WaxRenderer`): the stamps' pressure
        /// decides how far into the tooth the wax reaches, so a light stroke catches only the peaks and the
        /// paper shows through. `scale` 0.25…8 (1 is a 1.6-point tooth), `contrast` 0…1 (how much paper shows),
        /// `seed` picks the tooth. Always drawn on the stamp path. An older build, which doesn't know it,
        /// decodes it as `none` and draws the same stamps solid.
        case wax(scale: CGFloat, contrast: CGFloat, seed: UInt32)
    }

    /// Random variation per stamp (stamp path only), each 0…1 except `scatter`.
    public struct Jitter: Codable, Hashable, Sendable {
        /// Up to ±50% of the stamp's size at 1.
        public var size: CGFloat
        /// Up to ±π of extra rotation at 1.
        public var angle: CGFloat
        /// 0…2: sideways displacement, in nib widths.
        public var scatter: CGFloat
        /// Up to all of the stamp's opacity at 1.
        public var opacity: CGFloat
        /// Seeds the variation, so a stroke looks the same every time it's drawn.
        public var seed: UInt32

        public init(size: CGFloat = 0, angle: CGFloat = 0, scatter: CGFloat = 0, opacity: CGFloat = 0,
                    seed: UInt32 = 0) {
            self.size = size
            self.angle = angle
            self.scatter = scatter
            self.opacity = opacity
            self.seed = seed
        }

        public static let none = Jitter()

        var isActive: Bool {
            size > 0 || angle > 0 || scatter > 0 || opacity > 0
        }
    }

    /// Dashes along the stroke: `on` of ink, then `off` of gap, both in multiples of the full-pressure
    /// width (`size.upperBound`) and measured between stamp centres, so the visible gap is about one width
    /// shorter than `off` and the dash one width longer than `on`. `on` 0.05…50, `off` 0…50; `off` 0 is solid.
    public struct Dash: Codable, Hashable, Sendable {
        public var on: CGFloat
        public var off: CGFloat

        public init(on: CGFloat, off: CGFloat) {
            self.on = on
            self.off = off
        }

        /// Solid.
        public static let none = Dash(on: 1, off: 0)

        var isActive: Bool {
            off > 0
        }
    }

    /// How a stroke composites onto the page.
    public enum BlendMode: String, Codable, Hashable, Sendable, CaseIterable {
        /// Source-over.
        case normal
        /// Multiply, so ink underneath stays readable (highlighters).
        case multiply
        /// Removes the pixels of strokes drawn before it (the pixel eraser).
        case destinationOut

        var cgBlendMode: CGBlendMode {
            switch self {
            case .normal: .normal
            case .multiply: .multiply
            case .destinationOut: .destinationOut
            }
        }
    }

    public enum RenderPath: Sendable {
        /// The nib swept continuously: tangent strips between nib ellipses.
        case hull
        /// Separate nib stamps along the stroke.
        case stamp
    }

    // MARK: Derived

    public var renderPath: RenderPath {
        if spacing > 0 || dash.isActive {
            return .stamp
        }
        switch texture {
        case .bristle, .wax: return .stamp
        case .none, .grain: return .hull
        }
    }

    /// Distance between stamps in nib widths on the stamp path (a bristle or dashed brush with `spacing` 0
    /// gets 0.15).
    var stampSpacing: CGFloat {
        spacing > 0 ? spacing : 0.15
    }

    /// The pixel eraser and anything else that removes ink rather than adding it.
    public var erases: Bool {
        blend == .destinationOut
    }

    /// Whether the fill is a pattern (grain texture) that needs the context's pattern phase set. A wax
    /// texture counts: it falls back to the grain pattern where Metal isn't available.
    var usesPattern: Bool {
        switch texture {
        case .grain, .wax: true
        case .none, .bristle: false
        }
    }

    /// Whether strokes of this brush are rasterized on the GPU (`WaxRenderer`) instead of filled as paths.
    var isRaster: Bool {
        if case .wax = texture {
            return true
        }
        return false
    }

    /// Whether drawing needs the arc length at each point: for the taper, or to place the dashes.
    var measuresDistance: Bool {
        taper.isActive || dash.isActive
    }

    /// Whether the nib depends on the stroke's speed.
    var usesSpeed: Bool {
        velocity.isActive || wetness > 0
    }

    // MARK: Clamping

    public static let maxNameLength = 80

    /// This descriptor with every parameter pulled into its legal range. Idempotent.
    public func clamped() -> BrushDescriptor {
        let pen = BrushDescriptor.pen
        var b = self
        if b.name.count > Self.maxNameLength {
            b.name = String(b.name.prefix(Self.maxNameLength))
        }
        b.tip = tip.clamped()
        let upper = clamp(size.upperBound, 0.05 ... 1000, fallback: pen.size.upperBound)
        let lower = clamp(size.lowerBound, 0 ... upper, fallback: upper * 0.25)
        b.size = lower ... upper
        b.pressure = pressure.clamped(fallback: pen.pressure)
        b.pressureOpacity = pressureOpacity.clamped(fallback: .none)
        b.tilt = tilt.clamped()
        b.velocity = velocity.clamped(fallback: .none)
        b.taper = taper.clamped()
        b.smoothing = clamp(smoothing, 0 ... 0.95, fallback: 0)
        b.texture = texture.clamped()
        let spacing = clamp(spacing, 0 ... 4, fallback: 0)
        b.spacing = spacing < 0.025 ? 0 : max(spacing, 0.05)
        b.jitter = jitter.clamped()
        b.dash = dash.clamped()
        b.wetness = clamp(wetness, 0 ... 1, fallback: 0)
        b.opacity = clamp(opacity, 0.02 ... 1, fallback: 1)
        return b
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, tip, size, pressure, pressureOpacity, tilt, velocity, taper, smoothing, texture, spacing,
             jitter, dash, wetness, blend, opacity
    }

    /// Lenient: a missing or malformed field takes the pen's value, and the result is `clamped()`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pen = BrushDescriptor.pen
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let size = field(.size, [CGFloat]())
        self.init(id: field(.id, UUID()),
                  name: field(.name, "Brush"),
                  tip: field(.tip, pen.tip),
                  size: size.count == 2 && size.allSatisfy(\.isFinite)
                      ? min(size[0], size[1]) ... max(size[0], size[1]) : pen.size,
                  pressure: field(.pressure, pen.pressure),
                  pressureOpacity: field(.pressureOpacity, pen.pressureOpacity),
                  tilt: field(.tilt, pen.tilt),
                  velocity: field(.velocity, pen.velocity),
                  taper: field(.taper, pen.taper),
                  smoothing: field(.smoothing, pen.smoothing),
                  texture: field(.texture, pen.texture),
                  spacing: field(.spacing, pen.spacing),
                  jitter: field(.jitter, pen.jitter),
                  dash: field(.dash, pen.dash),
                  wetness: field(.wetness, pen.wetness),
                  blend: field(.blend, pen.blend),
                  opacity: field(.opacity, pen.opacity))
        self = clamped()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(tip, forKey: .tip)
        try c.encode([size.lowerBound, size.upperBound], forKey: .size)
        try c.encode(pressure, forKey: .pressure)
        try c.encode(pressureOpacity, forKey: .pressureOpacity)
        try c.encode(tilt, forKey: .tilt)
        try c.encode(velocity, forKey: .velocity)
        try c.encode(taper, forKey: .taper)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(texture, forKey: .texture)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(jitter, forKey: .jitter)
        if dash.isActive { // omitted when solid, so brushes without dashes keep the bytes they had
            try c.encode(dash, forKey: .dash)
        }
        try c.encode(wetness, forKey: .wetness)
        try c.encode(blend, forKey: .blend)
        try c.encode(opacity, forKey: .opacity)
    }

    /// Decodes a descriptor from JSON (lenient and clamped, see `init(from:)`).
    public init(json: Data) throws {
        self = try JSONDecoder().decode(BrushDescriptor.self, from: json)
    }

    /// Stable JSON for the descriptor: sorted keys, so equal descriptors give equal bytes.
    public func jsonData(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Clamping helpers

/// `v` pulled into `range`, or `fallback` (itself clamped) if it's NaN.
private func clamp(_ v: CGFloat, _ range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
    let x = v.isNaN ? fallback : v
    return min(max(x.isNaN ? range.lowerBound : x, range.lowerBound), range.upperBound)
}

private extension BrushDescriptor.TipShape {
    func clamped() -> Self {
        switch self {
        case .round:
            return .round
        case let .ellipse(aspect, angle):
            let a = clamp(aspect, 0.05 ... 1, fallback: 1)
            // In-range angles are kept as they are (atan2 would round them), so clamping stays exact.
            let t = !angle.isFinite ? 0 : (-CGFloat.pi ... CGFloat.pi).contains(angle) ? angle : atan2(sin(angle), cos(angle))
            return .ellipse(aspect: a, angle: t)
        }
    }
}

private extension BrushDescriptor.ResponseCurve {
    func clamped(fallback: Self) -> Self {
        Self(amount: clamp(amount, 0 ... 1, fallback: fallback.amount),
             exponent: clamp(exponent, 0.1 ... 5, fallback: fallback.exponent))
    }
}

private extension BrushDescriptor.TiltResponse {
    func clamped() -> Self {
        let d = Self.standard
        let start = clamp(startAltitude, 1 ... 89, fallback: d.startAltitude)
        return Self(enabled: enabled,
                    startAltitude: start,
                    fullAltitude: clamp(fullAltitude, 0 ... start - 1, fallback: min(d.fullAltitude, start - 1)),
                    length: clamp(length, 0 ... 8, fallback: d.length),
                    breadth: clamp(breadth, 0 ... 4, fallback: d.breadth),
                    opacityLoss: clamp(opacityLoss, 0 ... 1, fallback: d.opacityLoss),
                    contactShift: clamp(contactShift, 0 ... 1, fallback: d.contactShift))
    }
}

private extension BrushDescriptor.Taper {
    func clamped() -> Self {
        Self(startLength: clamp(startLength, 0 ... 500, fallback: 0),
             endLength: clamp(endLength, 0 ... 500, fallback: 0),
             minimumScale: clamp(minimumScale, 0 ... 1, fallback: 0.1))
    }
}

private extension BrushDescriptor.Texture {
    func clamped() -> Self {
        switch self {
        case .none:
            .none
        case let .grain(scale, contrast, seed):
            .grain(scale: clamp(scale, 0.25 ... 8, fallback: 1), contrast: clamp(contrast, 0 ... 1, fallback: 1),
                   seed: seed)
        case let .bristle(count, spread):
            .bristle(count: min(max(count, 1), 64), spread: clamp(spread, 0.1 ... 2, fallback: 1))
        case let .wax(scale, contrast, seed):
            .wax(scale: clamp(scale, 0.25 ... 8, fallback: 1), contrast: clamp(contrast, 0 ... 1, fallback: 0.8),
                 seed: seed)
        }
    }
}

private extension BrushDescriptor.Dash {
    func clamped() -> Self {
        Self(on: clamp(on, 0.05 ... 50, fallback: 1), off: clamp(off, 0 ... 50, fallback: 0))
    }
}

private extension BrushDescriptor.Jitter {
    func clamped() -> Self {
        Self(size: clamp(size, 0 ... 1, fallback: 0), angle: clamp(angle, 0 ... 1, fallback: 0),
             scatter: clamp(scatter, 0 ... 2, fallback: 0), opacity: clamp(opacity, 0 ... 1, fallback: 0),
             seed: seed)
    }
}

// MARK: - Lenient Codable for the parameter types

// A partial object keeps the fields it has: `{"tilt": {"enabled": false}}` turns tilt off and leaves the
// rest at their defaults.

extension BrushDescriptor.ResponseCurve {
    private enum Keys: String, CodingKey {
        case amount, exponent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(amount: (try? c.decodeIfPresent(CGFloat.self, forKey: .amount)) ?? 1,
                  exponent: (try? c.decodeIfPresent(CGFloat.self, forKey: .exponent)) ?? 1)
    }
}

extension BrushDescriptor.TiltResponse {
    private enum Keys: String, CodingKey {
        case enabled, startAltitude, fullAltitude, length, breadth, opacityLoss, contactShift
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = Self.standard
        func value(_ key: Keys, _ fallback: CGFloat) -> CGFloat {
            (try? c.decodeIfPresent(CGFloat.self, forKey: key)) ?? fallback
        }
        self.init(enabled: (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled,
                  startAltitude: value(.startAltitude, d.startAltitude),
                  fullAltitude: value(.fullAltitude, d.fullAltitude),
                  length: value(.length, d.length), breadth: value(.breadth, d.breadth),
                  opacityLoss: value(.opacityLoss, d.opacityLoss), contactShift: value(.contactShift, d.contactShift))
    }
}

extension BrushDescriptor.Taper {
    private enum Keys: String, CodingKey {
        case startLength, endLength, minimumScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(startLength: (try? c.decodeIfPresent(CGFloat.self, forKey: .startLength)) ?? 0,
                  endLength: (try? c.decodeIfPresent(CGFloat.self, forKey: .endLength)) ?? 0,
                  minimumScale: (try? c.decodeIfPresent(CGFloat.self, forKey: .minimumScale)) ?? 0.1)
    }
}

extension BrushDescriptor.Dash {
    private enum Keys: String, CodingKey {
        case on, off
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(on: (try? c.decodeIfPresent(CGFloat.self, forKey: .on)) ?? 1,
                  off: (try? c.decodeIfPresent(CGFloat.self, forKey: .off)) ?? 0)
    }
}

extension BrushDescriptor.Jitter {
    private enum Keys: String, CodingKey {
        case size, angle, scatter, opacity, seed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func value(_ key: Keys) -> CGFloat {
            (try? c.decodeIfPresent(CGFloat.self, forKey: key)) ?? 0
        }
        self.init(size: value(.size), angle: value(.angle), scatter: value(.scatter), opacity: value(.opacity),
                  seed: (try? c.decodeIfPresent(UInt32.self, forKey: .seed)) ?? 0)
    }
}

// MARK: - Codable for the enums

// Enums are keyed by case name: `"round"`, `{"ellipse": {"aspect": 0.3, "angle": 0.7}}`,
// `{"grain": {"scale": 1, "contrast": 1, "seed": 42}}`. An unknown case fails to decode, and the
// descriptor's lenient decoder then uses the pen's value.

extension BrushDescriptor.TipShape: Codable {
    private enum Keys: String, CodingKey {
        case ellipse
    }

    private enum EllipseKeys: String, CodingKey {
        case aspect, angle
    }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard name == "round" else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown tip"))
            }
            self = .round
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let e = try c.nestedContainer(keyedBy: EllipseKeys.self, forKey: .ellipse)
        self = try .ellipse(aspect: e.decodeIfPresent(CGFloat.self, forKey: .aspect) ?? 1,
                            angle: e.decodeIfPresent(CGFloat.self, forKey: .angle) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .round:
            var c = encoder.singleValueContainer()
            try c.encode("round")
        case let .ellipse(aspect, angle):
            var c = encoder.container(keyedBy: Keys.self)
            var e = c.nestedContainer(keyedBy: EllipseKeys.self, forKey: .ellipse)
            try e.encode(aspect, forKey: .aspect)
            try e.encode(angle, forKey: .angle)
        }
    }
}

extension BrushDescriptor.Texture: Codable {
    private enum Keys: String, CodingKey {
        case grain, bristle, wax
    }

    private enum FieldKeys: String, CodingKey {
        case scale, contrast, seed, count, spread
    }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard name == "none" else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "unknown texture"))
            }
            self = .none
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.grain) {
            let g = try c.nestedContainer(keyedBy: FieldKeys.self, forKey: .grain)
            self = try .grain(scale: g.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1,
                              contrast: g.decodeIfPresent(CGFloat.self, forKey: .contrast) ?? 1,
                              seed: g.decodeIfPresent(UInt32.self, forKey: .seed) ?? 42)
        } else if c.contains(.wax) {
            let w = try c.nestedContainer(keyedBy: FieldKeys.self, forKey: .wax)
            self = try .wax(scale: w.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1,
                            contrast: w.decodeIfPresent(CGFloat.self, forKey: .contrast) ?? 0.8,
                            seed: w.decodeIfPresent(UInt32.self, forKey: .seed) ?? 0)
        } else {
            let b = try c.nestedContainer(keyedBy: FieldKeys.self, forKey: .bristle)
            self = try .bristle(count: b.decodeIfPresent(Int.self, forKey: .count) ?? 8,
                                spread: b.decodeIfPresent(CGFloat.self, forKey: .spread) ?? 1)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .none:
            var c = encoder.singleValueContainer()
            try c.encode("none")
        case let .grain(scale, contrast, seed):
            var c = encoder.container(keyedBy: Keys.self)
            var g = c.nestedContainer(keyedBy: FieldKeys.self, forKey: .grain)
            try g.encode(scale, forKey: .scale)
            try g.encode(contrast, forKey: .contrast)
            try g.encode(seed, forKey: .seed)
        case let .bristle(count, spread):
            var c = encoder.container(keyedBy: Keys.self)
            var b = c.nestedContainer(keyedBy: FieldKeys.self, forKey: .bristle)
            try b.encode(count, forKey: .count)
            try b.encode(spread, forKey: .spread)
        case let .wax(scale, contrast, seed):
            var c = encoder.container(keyedBy: Keys.self)
            var w = c.nestedContainer(keyedBy: FieldKeys.self, forKey: .wax)
            try w.encode(scale, forKey: .scale)
            try w.encode(contrast, forKey: .contrast)
            try w.encode(seed, forKey: .seed)
        }
    }
}
