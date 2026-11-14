import Foundation

/// The ink tools a pen can be: what a saved pen switches to, and whose quick sizes, quick colours and
/// custom brushes a `ToolPresets` holds.
public enum PenKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case pen, pencil, highlighter

    public var id: String {
        rawValue
    }
}

/// A pen the user saved to the pen tray: a brush, a colour and a width, under a name. Choosing it switches
/// to its tool and draws with exactly that brush, colour and width.
///
/// The brush is a full snapshot of its `BrushDescriptor`, so a pen is self-contained: it still works if the
/// brush it was made from is edited or deleted, and it can be synced as it is.
public struct SavedPen: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// At most `PenTray.maxNameLength` characters.
    public var name: String
    public var kind: PenKind
    public var brush: BrushDescriptor
    public var color: PenColor
    /// Full-pressure width in points.
    public var width: Double
    /// When the pen was saved or last changed, for merging copies from other devices later.
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, kind: PenKind, brush: BrushDescriptor, color: PenColor,
                width: Double, modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.brush = brush
        self.color = color
        self.width = width
        self.modifiedAt = PenTray.stamp(modifiedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, brush, color, width, modifiedAt
    }

    /// Lenient like `BrushDescriptor`: only an unreadable kind, brush or colour makes a pen unreadable
    /// (and the tray then skips it); everything else falls back.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? nil
        try self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                      name: PenTray.cleanName((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil, or: "Pen"),
                      kind: c.decode(PenKind.self, forKey: .kind),
                      brush: c.decode(BrushDescriptor.self, forKey: .brush),
                      color: c.decode(PenColor.self, forKey: .color),
                      width: width.map { $0.isFinite ? min(max($0, 0.05), 1000) : 4 } ?? 4,
                      modifiedAt: (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? Date(timeIntervalSince1970: 0))
    }
}

/// A named set of colours the user keeps for the colour picker.
public struct ColorPalette: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var colors: [PenColor]
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, colors: [PenColor] = [], modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colors = colors
        self.modifiedAt = PenTray.stamp(modifiedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colors, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  name: PenTray.cleanName((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil, or: "Palette"),
                  colors: Array(c.lossy([PenColor].self, forKey: .colors).prefix(PenTray.maxPaletteColors)),
                  modifiedAt: (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? Date(timeIntervalSince1970: 0))
    }
}

/// One tool's quick sizes and colours, and the brushes the user made for it.
public struct ToolPresets: Codable, Hashable, Sendable {
    /// The three quick widths, fine to bold; nil uses the tool's defaults.
    public var sizes: [Double]?
    /// The quick colours in the Pen Case; nil uses the theme's inks.
    public var colors: [PenColor]?
    /// Brushes made in the brush editor, shown after the built-in ones in the brush picker.
    public var brushes: [BrushDescriptor]

    public init(sizes: [Double]? = nil, colors: [PenColor]? = nil, brushes: [BrushDescriptor] = []) {
        self.sizes = sizes
        self.colors = colors
        self.brushes = brushes
    }

    private enum CodingKeys: String, CodingKey {
        case sizes, colors, brushes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sizes = (try? c.decodeIfPresent([Double].self, forKey: .sizes)) ?? nil
        let colors = c.lossyIfPresent([PenColor].self, forKey: .colors)
        self.init(sizes: sizes.flatMap { $0.count == PenTray.quickSizeCount && $0.allSatisfy(\.isFinite) ? $0 : nil },
                  colors: colors.flatMap { $0.isEmpty ? nil : Array($0.prefix(PenTray.maxQuickColors)) },
                  brushes: c.lossy([BrushDescriptor].self, forKey: .brushes))
    }

    public static let empty = ToolPresets()
}

/// Everything the user keeps between notes and launches: saved pens in their order, each tool's quick sizes,
/// quick colours and custom brushes, colour palettes and recent colours.
///
/// Plain `Codable` data with stable ids, an explicit order and modification dates, so it can be synced
/// later. `PenTrayStore` saves it as JSON. Decoding is lenient: a newer or damaged file keeps whatever
/// it can read.
public struct PenTray: Codable, Hashable, Sendable {
    /// The JSON's `version`. Readers accept any version, reading the fields they know.
    public static let formatVersion = 1
    public static let maxNameLength = 60
    public static let quickSizeCount = 3
    public static let maxQuickColors = 8
    public static let maxRecentColors = 12
    public static let maxPaletteColors = 48

    /// In tray order.
    public var pens: [SavedPen]
    public var penPresets: ToolPresets
    public var pencilPresets: ToolPresets
    public var highlighterPresets: ToolPresets
    public var palettes: [ColorPalette]
    /// Newest first, no repeats, at most `maxRecentColors`.
    public var recentColors: [PenColor]

    public init(pens: [SavedPen] = [], penPresets: ToolPresets = .empty, pencilPresets: ToolPresets = .empty,
                highlighterPresets: ToolPresets = .empty, palettes: [ColorPalette] = [],
                recentColors: [PenColor] = []) {
        self.pens = pens
        self.penPresets = penPresets
        self.pencilPresets = pencilPresets
        self.highlighterPresets = highlighterPresets
        self.palettes = palettes
        self.recentColors = recentColors
    }

    /// A tool's presets.
    public subscript(presets kind: PenKind) -> ToolPresets {
        get {
            switch kind {
            case .pen: penPresets
            case .pencil: pencilPresets
            case .highlighter: highlighterPresets
            }
        }
        set {
            switch kind {
            case .pen: penPresets = newValue
            case .pencil: pencilPresets = newValue
            case .highlighter: highlighterPresets = newValue
            }
        }
    }

    // MARK: Pens

    /// Adds `pen` at the end of the tray.
    public mutating func add(_ pen: SavedPen) {
        var pen = pen
        pen.name = Self.cleanName(pen.name, or: pen.brush.name)
        pens.removeAll { $0.id == pen.id }
        pens.append(pen)
    }

    public mutating func removePen(id: UUID) {
        pens.removeAll { $0.id == id }
    }

    /// Renames a pen; a blank name is ignored.
    public mutating func renamePen(id: UUID, to name: String, at date: Date = Date()) {
        guard let i = pens.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.cleanName(name, or: "")
        guard !clean.isEmpty, clean != pens[i].name else { return }
        pens[i].name = clean
        pens[i].modifiedAt = Self.stamp(date)
    }

    /// Replaces a pen's brush, colour and width (keeping its name, id and place).
    public mutating func updatePen(id: UUID, kind: PenKind, brush: BrushDescriptor, color: PenColor, width: Double,
                                   at date: Date = Date()) {
        guard let i = pens.firstIndex(where: { $0.id == id }) else { return }
        pens[i].kind = kind
        pens[i].brush = brush
        pens[i].color = color
        pens[i].width = width
        pens[i].modifiedAt = Self.stamp(date)
    }

    /// Moves the pens at `source` to before the pen at `destination`, like `List`'s `onMove`.
    public mutating func movePens(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { pens.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { pens[$0] }
        var rest = pens
        for i in valid.reversed() {
            rest.remove(at: i)
        }
        let target = min(max(destination, 0), pens.count)
        let insertAt = target - valid.filter { $0 < target }.count
        rest.insert(contentsOf: moving, at: insertAt)
        pens = rest
    }

    /// Moves a pen one place earlier (`by: -1`) or later (`by: 1`).
    public mutating func movePen(id: UUID, by offset: Int) {
        guard let i = pens.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), pens.count - 1)
        guard j != i else { return }
        pens.insert(pens.remove(at: i), at: j)
    }

    // MARK: Quick sizes and colours

    /// Sets quick size `index` of `kind`, starting from `defaults` if the tool has no sizes of its own.
    public mutating func setQuickSize(_ width: Double, at index: Int, for kind: PenKind, defaults: [Double]) {
        guard width.isFinite else { return }
        var sizes = self[presets: kind].sizes ?? defaults
        guard sizes.indices.contains(index) else { return }
        sizes[index] = width
        self[presets: kind].sizes = sizes
    }

    public mutating func resetQuickSizes(for kind: PenKind) {
        self[presets: kind].sizes = nil
    }

    /// Sets quick colour `index` of `kind`, starting from `defaults` (the theme's inks) if the tool has
    /// no colours of its own.
    public mutating func setQuickColor(_ color: PenColor, at index: Int, for kind: PenKind, defaults: [PenColor]) {
        var colors = self[presets: kind].colors ?? defaults
        guard colors.indices.contains(index) else { return }
        colors[index] = color
        self[presets: kind].colors = colors
    }

    public mutating func resetQuickColors(for kind: PenKind) {
        self[presets: kind].colors = nil
    }

    // MARK: Recent colours

    /// Puts `color` at the front of the recent colours.
    public mutating func addRecentColor(_ color: PenColor) {
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > Self.maxRecentColors {
            recentColors.removeLast(recentColors.count - Self.maxRecentColors)
        }
    }

    // MARK: Palettes

    /// Adds a palette and returns its id.
    @discardableResult
    public mutating func addPalette(named name: String, colors: [PenColor] = [], at date: Date = Date()) -> UUID {
        let palette = ColorPalette(name: Self.cleanName(name, or: "Palette \(palettes.count + 1)"),
                                   colors: Array(colors.prefix(Self.maxPaletteColors)), modifiedAt: date)
        palettes.append(palette)
        return palette.id
    }

    public mutating func renamePalette(id: UUID, to name: String, at date: Date = Date()) {
        guard let i = palettes.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.cleanName(name, or: "")
        guard !clean.isEmpty else { return }
        palettes[i].name = clean
        palettes[i].modifiedAt = Self.stamp(date)
    }

    public mutating func removePalette(id: UUID) {
        palettes.removeAll { $0.id == id }
    }

    /// Adds `color` to the end of a palette, unless it's already there or the palette is full.
    public mutating func addColor(_ color: PenColor, toPalette id: UUID, at date: Date = Date()) {
        guard let i = palettes.firstIndex(where: { $0.id == id }), !palettes[i].colors.contains(color),
              palettes[i].colors.count < Self.maxPaletteColors else { return }
        palettes[i].colors.append(color)
        palettes[i].modifiedAt = Self.stamp(date)
    }

    public mutating func removeColor(_ color: PenColor, fromPalette id: UUID, at date: Date = Date()) {
        guard let i = palettes.firstIndex(where: { $0.id == id }) else { return }
        palettes[i].colors.removeAll { $0 == color }
        palettes[i].modifiedAt = Self.stamp(date)
    }

    // MARK: Custom brushes

    /// Adds `brush` to `kind`'s brushes, or replaces the one with its id.
    public mutating func saveBrush(_ brush: BrushDescriptor, for kind: PenKind) {
        let brush = brush.clamped()
        if let i = self[presets: kind].brushes.firstIndex(where: { $0.id == brush.id }) {
            self[presets: kind].brushes[i] = brush
        } else {
            self[presets: kind].brushes.append(brush)
        }
    }

    public mutating func removeBrush(id: UUID, for kind: PenKind) {
        self[presets: kind].brushes.removeAll { $0.id == id }
    }

    // MARK: Dates

    /// `date` to the whole second, as the JSON stores it, so a tray read back equals the one saved.
    static func stamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: Names

    /// `name` trimmed and cut to `maxNameLength`, or `fallback` if that leaves nothing.
    static func cleanName(_ name: String?, or fallback: String) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(maxNameLength))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, pens, presets, palettes, recentColors
    }

    private enum PresetKeys: String, CodingKey {
        case pen, pencil, highlighter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var pens: [SavedPen] = []
        for pen in c.lossy([SavedPen].self, forKey: .pens) where !pens.contains(where: { $0.id == pen.id }) {
            pens.append(pen)
        }
        let presets = try? c.nestedContainer(keyedBy: PresetKeys.self, forKey: .presets)
        func preset(_ key: PresetKeys) -> ToolPresets {
            ((try? presets?.decodeIfPresent(ToolPresets.self, forKey: key)) ?? nil) ?? .empty
        }
        var recents: [PenColor] = []
        for color in c.lossy([PenColor].self, forKey: .recentColors) where !recents.contains(color) {
            recents.append(color)
        }
        self.init(pens: pens, penPresets: preset(.pen), pencilPresets: preset(.pencil),
                  highlighterPresets: preset(.highlighter), palettes: c.lossy([ColorPalette].self, forKey: .palettes),
                  recentColors: Array(recents.prefix(Self.maxRecentColors)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(pens, forKey: .pens)
        var presets = c.nestedContainer(keyedBy: PresetKeys.self, forKey: .presets)
        try presets.encode(penPresets, forKey: .pen)
        try presets.encode(pencilPresets, forKey: .pencil)
        try presets.encode(highlighterPresets, forKey: .highlighter)
        try c.encode(palettes, forKey: .palettes)
        try c.encode(recentColors, forKey: .recentColors)
    }

    /// Stable JSON: sorted keys, ISO 8601 dates.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads JSON written by `jsonData()` (leniently, see the type's documentation).
    public init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(PenTray.self, from: json)
    }
}

// MARK: - Lossy arrays

/// Decodes any element, or nothing, so one unreadable element doesn't lose the array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// The readable elements of the array at `key`; empty if there's no array.
    func lossy<T: Decodable>(_: [T].Type, forKey key: Key) -> [T] {
        lossyIfPresent([T].self, forKey: key) ?? []
    }

    /// The readable elements of the array at `key`; nil if there's no array.
    func lossyIfPresent<T: Decodable>(_: [T].Type, forKey key: Key) -> [T]? {
        guard let items = (try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil else { return nil }
        return items.compactMap(\.value)
    }
}
