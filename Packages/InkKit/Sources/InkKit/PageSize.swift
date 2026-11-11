import CoreGraphics
import Foundation

/// Physical size of a page, in PostScript points (1/72 inch). Canvas units are points, so a Letter page
/// is a 612 × 792 canvas.
public struct PageSize: Hashable, Sendable, Codable {
    /// Smallest and largest edge accepted for a custom page: 1 inch to 200 inches.
    public static let minimumDimension: CGFloat = 72
    public static let maximumDimension: CGFloat = 14_400

    public let width: CGFloat
    public let height: CGFloat
    /// Display name of a preset ("Letter"), or nil for a custom size.
    public let name: String?

    /// A custom page. Each edge is clamped to `minimumDimension...maximumDimension`; non-finite values
    /// fall back to the minimum.
    public init(width: CGFloat, height: CGFloat, name: String? = nil) {
        self.width = Self.clamp(width)
        self.height = Self.clamp(height)
        self.name = name
    }

    /// A custom page measured in `unit`.
    public init(width: CGFloat, height: CGFloat, unit: Unit) {
        self.init(width: unit.toPoints(width), height: unit.toPoints(height))
    }

    /// A custom page measured in inches.
    public static func inches(width: CGFloat, height: CGFloat) -> PageSize {
        PageSize(width: width, height: height, unit: .inches)
    }

    /// A custom page measured in millimetres.
    public static func millimeters(width: CGFloat, height: CGFloat) -> PageSize {
        PageSize(width: width, height: height, unit: .millimeters)
    }

    /// Units a person can enter a custom size in.
    public enum Unit: String, CaseIterable, Identifiable, Sendable {
        case inches, millimeters, points
        public var id: String { rawValue }

        public var pointsPerUnit: CGFloat {
            switch self {
            case .inches: return 72
            case .millimeters: return 72 / 25.4
            case .points: return 1
            }
        }

        public var symbol: String {
            switch self {
            case .inches: return "in"
            case .millimeters: return "mm"
            case .points: return "pt"
            }
        }

        public func toPoints(_ value: CGFloat) -> CGFloat { value * pointsPerUnit }
        public func fromPoints(_ points: CGFloat) -> CGFloat { points / pointsPerUnit }

        /// The accepted range for one edge, in this unit.
        public var allowedRange: ClosedRange<CGFloat> {
            fromPoints(PageSize.minimumDimension)...fromPoints(PageSize.maximumDimension)
        }

        public static var localeDefault: Unit { Locale.current.measurementSystem == .us ? .inches : .millimeters }
    }

    // MARK: Presets

    public static let letter = PageSize(width: 612, height: 792, name: "Letter")
    public static let legal = PageSize(width: 612, height: 1008, name: "Legal")
    public static let tabloid = PageSize(width: 792, height: 1224, name: "Tabloid")
    public static let a3 = PageSize(width: 841.89, height: 1190.55, name: "A3")
    public static let a4 = PageSize(width: 595.28, height: 841.89, name: "A4")
    public static let a5 = PageSize(width: 419.53, height: 595.28, name: "A5")

    /// The default for new pages.
    public static let `default` = letter

    /// Presets offered in the page-size menu, in portrait.
    public static let presets: [PageSize] = [.letter, .legal, .tabloid, .a3, .a4, .a5]

    // MARK: Derived

    public var size: CGSize { CGSize(width: width, height: height) }
    /// The page rect in canvas space; pages start at the canvas origin.
    public var bounds: CGRect { CGRect(origin: .zero, size: size) }
    public var isLandscape: Bool { width > height }
    public var isCustom: Bool { name == nil }

    /// The same page turned to portrait (taller than wide). Square pages are unchanged.
    public var portrait: PageSize { isLandscape ? rotated : self }
    /// The same page turned to landscape (wider than tall). Square pages are unchanged.
    public var landscape: PageSize { height > width ? rotated : self }

    private var rotated: PageSize { PageSize(width: height, height: width, name: name) }

    /// "Letter", "Letter (Landscape)", or "8.5 × 11 in" / "210 × 297 mm" for custom sizes.
    public func displayName(metric: Bool = Locale.current.measurementSystem != .us) -> String {
        if let name { return isLandscape ? "\(name) (Landscape)" : name }
        if metric {
            return "\(Self.format(width / 72 * 25.4, digits: 0)) × \(Self.format(height / 72 * 25.4, digits: 0)) mm"
        }
        return "\(Self.format(width / 72, digits: 2)) × \(Self.format(height / 72, digits: 2)) in"
    }

    /// Two sizes are the same paper when their dimensions match to within a hundredth of a point,
    /// whatever they're called.
    public func hasSameDimensions(as other: PageSize) -> Bool {
        abs(width - other.width) < 0.01 && abs(height - other.height) < 0.01
    }

    private static func clamp(_ v: CGFloat) -> CGFloat {
        guard v.isFinite else { return minimumDimension }
        return min(max(v, minimumDimension), maximumDimension)
    }

    private static func format(_ v: CGFloat, digits: Int) -> String {
        Double(v).formatted(.number.precision(.fractionLength(0...digits)))
    }
}
