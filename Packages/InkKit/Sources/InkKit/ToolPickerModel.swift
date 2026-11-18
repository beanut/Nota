import CoreGraphics
import Foundation

// MARK: - Tools in the picker

/// One slot in the floating tool picker. Several draw with the same `Tool` and a different built-in brush
/// (the marker and fountain pen are pens; the crayon is a pencil), so each gets its own illustration and
/// remembers its own width. The ruler is a toggle, and Insert opens a menu rather than selecting a tool.
public enum PickerTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case pen, marker, fountainPen, pencil, crayon, highlighter, eraser, lasso, ruler, shapes, textBox
    case tape, laser, insert

    public var id: String {
        rawValue
    }

    /// The tools a new bar starts with, in order (Figma **ToolPicker/Bar**).
    public static let defaultBar: [PickerTool] = [.pen, .marker, .pencil, .eraser, .lasso, .ruler, .crayon, .fountainPen]

    /// The canvas tool this slot selects; nil for the ruler and Insert, which select nothing.
    var tool: Tool? {
        switch self {
        case .pen, .marker, .fountainPen: .pen
        case .pencil, .crayon: .pencil
        case .highlighter: .highlighter
        case .eraser: .eraser
        case .lasso: .lasso
        case .shapes: .shape
        case .textBox: .text
        case .tape: .tape
        case .laser: .laser
        case .ruler, .insert: nil
        }
    }

    /// The built-in brush this slot draws with, for the slots that share a tool. Nil keeps whatever brush
    /// the tool last used (the highlighter's brush picker still chooses between highlighters).
    var brushID: UUID? {
        switch self {
        case .pen: BrushDescriptor.pen.id
        case .marker: BrushDescriptor.marker.id
        case .fountainPen: BrushDescriptor.fountainPen.id
        case .pencil: BrushDescriptor.pencil.id
        case .crayon: BrushDescriptor.crayon.id
        default: nil
        }
    }

    /// Which slot shows as selected for the canvas's `tool` drawing with `brushID`: the slot whose brush it
    /// is, or for a brush no slot names (a fineliner, a custom brush) the tool's plain slot (pen, pencil).
    /// `inBar` limits the answer to slots that are in the bar, so a marker picked elsewhere still lights up
    /// the pen when the marker isn't in the bar.
    static func current(tool: Tool, brushID: UUID?, inBar: [PickerTool] = PickerTool.allCases) -> PickerTool? {
        let candidates = inBar.filter { $0.tool == tool }
        if let exact = candidates.first(where: { $0.brushID != nil && $0.brushID == brushID }) {
            return exact
        }
        return candidates.first { $0.brushID == nil || $0 == .pen || $0 == .pencil } ?? candidates.first
    }
}

// MARK: - Bar contents

/// The tools in the bar, in order, saved across launches. Every tool appears at most once; the bar is never
/// left empty.
public struct ToolPickerItems: Codable, Equatable, Sendable {
    public private(set) var tools: [PickerTool]

    public init(_ tools: [PickerTool] = PickerTool.defaultBar) {
        var seen = Set<PickerTool>()
        let unique = tools.filter { seen.insert($0).inserted }
        self.tools = unique.isEmpty ? PickerTool.defaultBar : unique
    }

    /// The tools the Plus popover offers: everything not already in the bar, in `PickerTool` order.
    public var addable: [PickerTool] {
        PickerTool.allCases.filter { !tools.contains($0) }
    }

    /// Appends `tool` to the end of the row (the Plus popover's Add).
    public mutating func add(_ tool: PickerTool) {
        guard !tools.contains(tool) else { return }
        tools.append(tool)
    }

    /// Takes `tool` out of the bar, unless it's the last one.
    public mutating func remove(_ tool: PickerTool) {
        guard tools.count > 1 else { return }
        tools.removeAll { $0 == tool }
    }

    public func canRemove(_ tool: PickerTool) -> Bool {
        tools.count > 1 && tools.contains(tool)
    }

    /// Moves `tool` one place towards the start (`by: -1`) or end (`by: 1`) of the row.
    public mutating func move(_ tool: PickerTool, by offset: Int) {
        guard let index = tools.firstIndex(of: tool) else { return }
        let target = index + offset
        guard tools.indices.contains(target) else { return }
        tools.swapAt(index, target)
    }

    static let defaultsKey = "InkKit.ToolPicker.items"

    static func load(from defaults: UserDefaults) -> ToolPickerItems {
        guard let data = defaults.data(forKey: defaultsKey),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return ToolPickerItems() }
        // Unknown tools (from a newer version) are dropped rather than failing the whole bar.
        return ToolPickerItems(raw.compactMap(PickerTool.init(rawValue:)))
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(tools.map(\.rawValue)) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Docking

/// Where the bar sits: bottom centre (the default), a lower corner, or along the top or a side edge. On a
/// side edge it runs vertically.
public enum ToolPickerDock: String, CaseIterable, Codable, Sendable {
    case bottom, bottomLeading, bottomTrailing, top, leading, trailing

    var isVertical: Bool {
        self == .leading || self == .trailing
    }

    static let defaultsKey = "InkKit.ToolPicker.dock"
}

/// The bar's measurements and the arithmetic of where it goes (Figma **ToolPicker/Bar**, State 03 and 07).
/// Pure, so it's tested without a view.
enum ToolPickerLayout {
    /// The capsule's thickness, and the collapsed circle's diameter.
    static let thickness: CGFloat = 52
    /// Every slot's touch target.
    static let slot: CGFloat = 44
    static let gap: CGFloat = 4
    /// Padding along the bar: before the first tool and after the collapse button.
    static let leadingPadding: CGFloat = 8
    static let trailingPadding: CGFloat = 6
    /// The fade over a tool row that has hidden tools at that edge.
    static let fade: CGFloat = 24
    /// Distance from the screen edges (inside the safe area).
    static let margin: CGFloat = 24
    /// The divider between groups.
    static let divider: CGFloat = 1

    /// Plus, divider, colour well, divider, undo, redo and collapse: everything after the tool row, with the
    /// gaps before each, and the padding at both ends.
    static var fixedLength: CGFloat {
        leadingPadding + trailingPadding + 5 * slot + 2 * divider + 7 * gap
    }

    /// The tool row's natural length for `count` tools.
    static func rowLength(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * slot + CGFloat(count - 1) * gap
    }

    /// The length of the tool row's viewport: the whole row while the bar fits along its edge, otherwise
    /// what's left of `maxLength` after the fixed controls (the row then scrolls). Never less than one slot.
    static func viewportLength(count: Int, maxLength: CGFloat) -> CGFloat {
        max(slot, min(rowLength(count: count), maxLength - fixedLength))
    }

    /// Whether the tool row needs to scroll at `maxLength`.
    static func overflows(count: Int, maxLength: CGFloat) -> Bool {
        rowLength(count: count) > maxLength - fixedLength
    }

    /// The bar's length along its edge.
    static func barLength(count: Int, maxLength: CGFloat) -> CGFloat {
        fixedLength + viewportLength(count: count, maxLength: maxLength)
    }

    /// How long the bar may grow on `dock` within `bounds` (the area it floats in, already inside the safe
    /// area and clear of the navigation row): the edge's length less the margins at both ends.
    static func maxLength(on dock: ToolPickerDock, in bounds: CGSize) -> CGFloat {
        (dock.isVertical ? bounds.height : bounds.width) - 2 * margin
    }

    /// The bar's centre when docked on `dock`, for a bar `length` long, within `bounds`.
    static func center(on dock: ToolPickerDock, length: CGFloat, in bounds: CGSize) -> CGPoint {
        let half = length / 2
        let edge = margin + thickness / 2
        switch dock {
        case .bottom: return CGPoint(x: bounds.width / 2, y: bounds.height - edge)
        case .bottomLeading: return CGPoint(x: margin + half, y: bounds.height - edge)
        case .bottomTrailing: return CGPoint(x: bounds.width - margin - half, y: bounds.height - edge)
        case .top: return CGPoint(x: bounds.width / 2, y: edge)
        case .leading: return CGPoint(x: edge, y: bounds.height / 2)
        case .trailing: return CGPoint(x: bounds.width - edge, y: bounds.height / 2)
        }
    }

    /// The dock nearest to where a dragged bar's centre was let go. Each dock is judged by where the bar's
    /// own centre would be on it, so a long bar dropped near a corner snaps there only when it's closer to
    /// the corner position than to bottom centre. A collapsed circle is judged by where the circle would be.
    static func nearestDock(to point: CGPoint, count: Int, in bounds: CGSize,
                            collapsed: Bool = false) -> ToolPickerDock {
        func center(of dock: ToolPickerDock) -> CGPoint {
            let length = barLength(count: count, maxLength: maxLength(on: dock, in: bounds))
            return collapsed
                ? collapsedCenter(on: dock, length: length, in: bounds)
                : Self.center(on: dock, length: length, in: bounds)
        }
        return ToolPickerDock.allCases.min { a, b in
            distance(point, center(of: a)) < distance(point, center(of: b))
        } ?? .bottom
    }

    /// Where the collapsed circle sits: at the trailing end of the bar it replaced (the bottom end on a
    /// side edge), where the collapse button was; in the lower-leading corner, in the corner itself.
    static func collapsedCenter(on dock: ToolPickerDock, length: CGFloat, in bounds: CGSize) -> CGPoint {
        let bar = center(on: dock, length: length, in: bounds)
        let shift = length / 2 - thickness / 2
        switch dock {
        case .bottomLeading: return CGPoint(x: bar.x - shift, y: bar.y)
        case .leading, .trailing: return CGPoint(x: bar.x, y: bar.y + shift)
        default: return CGPoint(x: bar.x + shift, y: bar.y)
        }
    }

    /// Thickness slider value (0…1) to a dot preview's diameter: 4 pt at the minimum, 24 pt at the maximum.
    static func previewDiameter(for value: Double) -> CGFloat {
        4 + CGFloat(min(max(value, 0), 1)) * 20
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
