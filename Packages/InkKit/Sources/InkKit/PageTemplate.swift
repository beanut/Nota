import CoreGraphics
import Foundation

/// What's printed on a page under the ink: the paper colour, a ruling pattern (lines, grid, dots, Cornell,
/// planners, …) and optionally a PDF page or image as a custom background.
///
/// A template is a plain value in page points, so it's stored with the page and drawn as vectors by
/// `TemplateRenderer`: crisp at every zoom, and real lines (not pixels) in an exported PDF. Its colours
/// come from the theme's `PaperPalette` for its `paper`, so they don't change in dark mode.
///
/// ```swift
/// page.template = PageTemplate.Preset.cornell.template
/// page.template.paper = .dark
/// ```
public struct PageTemplate: Hashable, Sendable {
    /// The ruling drawn on the paper.
    public enum Pattern: String, Codable, CaseIterable, Sendable {
        case blank, ruled, grid, dots, cornell, musicStaff, isometric, todo, weeklyPlanner, monthlyPlanner
    }

    /// Space left empty at each edge of the page, in points.
    public struct Insets: Hashable, Codable, Sendable {
        public var top: CGFloat
        public var left: CGFloat
        public var bottom: CGFloat
        public var right: CGFloat

        public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        public static let zero = Insets()

        public static func all(_ inset: CGFloat) -> Insets {
            Insets(top: inset, left: inset, bottom: inset, right: inset)
        }
    }

    public var pattern: Pattern
    /// The pattern's pitch in points: the gap between ruled lines, a grid cell, the dot pitch, the gap
    /// between a staff's lines, an isometric triangle's side, a to-do row. Clamped to 2...200.
    public var spacing: CGFloat {
        didSet { spacing = Self.clampSpacing(spacing) }
    }

    public var paper: PaperColor
    /// Where the pattern starts and stops. Ruled lines run to the page edges between `top` and `bottom`;
    /// grids, dots and planners fill the inset rectangle.
    public var margins: Insets
    /// A vertical margin rule `margins.left` in from the left edge (ruled and to-do pages).
    public var marginRule: Bool
    /// A PDF page or image drawn over the paper and under the pattern (usually with `pattern` `.blank`).
    /// The bytes are kept with the page as a `TemplateArtwork`; this only names them.
    public var background: TemplateBackground?

    public init(pattern: Pattern, spacing: CGFloat, paper: PaperColor = .white, margins: Insets = .zero,
                marginRule: Bool = false, background: TemplateBackground? = nil) {
        self.pattern = pattern
        self.spacing = Self.clampSpacing(spacing)
        self.paper = paper
        self.margins = margins
        self.marginRule = marginRule
        self.background = background
    }

    /// Plain white paper.
    public static let blank = Preset.blank.template
    /// The template new pages get when nothing else is given.
    public static let `default` = blank

    /// True when nothing but paper is drawn.
    public var isPlain: Bool {
        pattern == .blank && background == nil
    }

    /// The same template on another paper.
    public func on(_ paper: PaperColor) -> PageTemplate {
        var copy = self
        copy.paper = paper
        return copy
    }

    private static func clampSpacing(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 18 }
        return min(max(value, 2), 200)
    }
}

// MARK: - Paper

/// The colour of the sheet. The theme maps each to a `PaperPalette`.
public enum PaperColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case white, cream, dark

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .white: String(localized: "White")
        case .cream: String(localized: "Cream")
        case .dark: String(localized: "Dark")
        }
    }
}

/// The colours a paper is drawn in. Fixed colours, not dynamic ones: paper looks the same in light and
/// dark mode.
public struct PaperPalette: Equatable, @unchecked Sendable {
    /// The sheet.
    public var surface: CGColor
    /// Ruled lines, grid lines, dots, staves, checkboxes.
    public var rule: CGColor
    /// The margin rule and the dividers of Cornell and planner pages.
    public var accent: CGColor
    /// Planner labels (weekday names).
    public var label: CGColor

    public init(surface: CGColor, rule: CGColor, accent: CGColor, label: CGColor) {
        self.surface = surface
        self.rule = rule
        self.accent = accent
        self.label = label
    }

    /// InkKit's own palettes, used by `InkTheme.standard`. `white` is `surface` white paper.
    public static func standard(_ paper: PaperColor, white surface: CGColor = CGColor(gray: 1, alpha: 1)) -> PaperPalette {
        switch paper {
        case .white:
            PaperPalette(surface: surface, rule: .srgb(0xD5DBE6), accent: .srgb(0xEBA9A9), label: .srgb(0x8E94A0))
        case .cream:
            PaperPalette(surface: .srgb(0xF8F1DF), rule: .srgb(0xE0D5BB), accent: .srgb(0xE2A493), label: .srgb(0x9A8E74))
        case .dark:
            PaperPalette(surface: .srgb(0x26282C), rule: .srgb(0x41454D), accent: .srgb(0x74505A), label: .srgb(0x868C97))
        }
    }
}

extension CGColor {
    static func srgb(_ hex: UInt32) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Custom backgrounds

/// Names the PDF page or image a template is drawn on. The bytes live in a `TemplateArtwork` with the
/// same `id`, which the host stores next to the page.
public struct TemplateBackground: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pdf, image

        /// File extension for storing the bytes.
        public var fileExtension: String {
            self == .pdf ? "pdf" : "img"
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Which page of a PDF, from 0.
    public var pageIndex: Int

    public init(id: UUID = UUID(), kind: Kind, pageIndex: Int = 0) {
        self.id = id
        self.kind = kind
        self.pageIndex = max(0, pageIndex)
    }
}

// MARK: - Presets

public extension PageTemplate {
    /// The built-in templates, in the order the template menu shows them.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case blank, narrowRuled, collegeRuled, wideRuled, smallGrid, largeGrid, dots, cornell, musicStaff,
             isometric, todo, weeklyPlanner, monthlyPlanner

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .blank: String(localized: "Blank")
            case .narrowRuled: String(localized: "Narrow Ruled")
            case .collegeRuled: String(localized: "College Ruled")
            case .wideRuled: String(localized: "Wide Ruled")
            case .smallGrid: String(localized: "Small Grid")
            case .largeGrid: String(localized: "Large Grid")
            case .dots: String(localized: "Dotted")
            case .cornell: String(localized: "Cornell")
            case .musicStaff: String(localized: "Music Staff")
            case .isometric: String(localized: "Isometric")
            case .todo: String(localized: "To-Do")
            case .weeklyPlanner: String(localized: "Weekly Planner")
            case .monthlyPlanner: String(localized: "Monthly Planner")
            }
        }

        /// The preset on white paper.
        public var template: PageTemplate {
            let inch: CGFloat = 72, mm: CGFloat = 72 / 25.4
            let ruledMargins = Insets(top: inch, left: 1.25 * inch, bottom: 0.5 * inch, right: 0)
            return switch self {
            case .blank: PageTemplate(pattern: .blank, spacing: 18)
            case .narrowRuled: PageTemplate(pattern: .ruled, spacing: inch / 4, margins: ruledMargins, marginRule: true)
            case .collegeRuled: PageTemplate(pattern: .ruled, spacing: inch * 9 / 32, margins: ruledMargins, marginRule: true)
            case .wideRuled: PageTemplate(pattern: .ruled, spacing: inch * 11 / 32, margins: ruledMargins, marginRule: true)
            case .smallGrid: PageTemplate(pattern: .grid, spacing: 5 * mm)
            case .largeGrid: PageTemplate(pattern: .grid, spacing: 10 * mm)
            case .dots: PageTemplate(pattern: .dots, spacing: 5 * mm)
            case .cornell: PageTemplate(pattern: .cornell, spacing: inch * 9 / 32,
                                        margins: Insets(top: inch, left: 0, bottom: 0.5 * inch, right: 0))
            case .musicStaff: PageTemplate(pattern: .musicStaff, spacing: 7, margins: .all(0.75 * inch))
            case .isometric: PageTemplate(pattern: .isometric, spacing: 6 * mm)
            case .todo: PageTemplate(pattern: .todo, spacing: 0.4 * inch,
                                     margins: Insets(top: inch, left: 0.75 * inch, bottom: 0.5 * inch, right: 0.5 * inch))
            case .weeklyPlanner: PageTemplate(pattern: .weeklyPlanner, spacing: inch * 9 / 32, margins: .all(0.5 * inch))
            case .monthlyPlanner: PageTemplate(pattern: .monthlyPlanner, spacing: inch * 9 / 32, margins: .all(0.5 * inch))
            }
        }
    }

    /// The built-in `preset` on white paper.
    static func preset(_ preset: Preset) -> PageTemplate {
        preset.template
    }

    /// The built-in this template is (on any paper), or nil for a customised or custom-background one.
    var preset: Preset? {
        guard background == nil else { return nil }
        let plain = on(.white)
        return Preset.allCases.first { $0.template == plain }
    }

    /// The preset's name, or "Custom".
    var title: String {
        if background != nil {
            return String(localized: "Custom")
        }
        return preset?.title ?? String(localized: "Custom")
    }
}

// MARK: - Codable

extension PageTemplate: Codable {
    private enum CodingKeys: String, CodingKey {
        case pattern, spacing, paper, margins, marginRule, background
    }

    /// Unknown values (from a newer version) fall back to blank white paper rather than failing, so a page
    /// never becomes unreadable because of its template.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_: T.Type, _ key: CodingKeys) -> T? {
            try? c.decodeIfPresent(T.self, forKey: key)
        }
        self.init(pattern: value(Pattern.self, .pattern) ?? .blank,
                  spacing: value(CGFloat.self, .spacing) ?? 18,
                  paper: value(PaperColor.self, .paper) ?? .white,
                  margins: value(Insets.self, .margins) ?? .zero,
                  marginRule: value(Bool.self, .marginRule) ?? false,
                  background: value(TemplateBackground.self, .background))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(paper, forKey: .paper)
        try c.encode(margins, forKey: .margins)
        try c.encode(marginRule, forKey: .marginRule)
        try c.encodeIfPresent(background, forKey: .background)
    }
}
