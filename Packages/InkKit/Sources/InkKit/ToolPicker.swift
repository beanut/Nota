import SwiftUI

// MARK: - Picker tools in the chrome

extension PickerTool {
    var title: LocalizedStringKey {
        switch self {
        case .pen: "Pen"
        case .marker: "Marker"
        case .fountainPen: "Fountain Pen"
        case .pencil: "Pencil"
        case .crayon: "Crayon"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        case .ruler: "Ruler"
        case .shapes: "Shapes"
        case .textBox: "Text Box"
        case .tape: "Tape"
        case .laser: "Laser Pointer"
        case .insert: "Insert"
        }
    }

    /// The glyph drawn when the theme has no artwork for the tool.
    var glyph: InkIcon {
        switch self {
        case .pen, .marker, .fountainPen: .pen
        case .pencil, .crayon: .pencil
        case .highlighter: .highlighter
        case .eraser: .eraser
        case .lasso: .lasso
        case .ruler: .ruler
        case .shapes: .shapes
        case .textBox: .text
        case .tape: .tape
        case .laser: .laser
        case .insert: .photo
        }
    }

    /// Tapping the selected tool again opens colour & thickness for the drawing tools, and the tool's own
    /// options (eraser mode, lasso shape, shape style…) for the rest.
    var opensColorAndThickness: Bool {
        switch self {
        case .pen, .marker, .fountainPen, .pencil, .crayon, .highlighter: true
        default: false
        }
    }

    /// The flat artwork (lasso, shapes, text box) casts no shadow; the realistic tools do.
    var castsShadow: Bool {
        switch self {
        case .lasso, .shapes, .textBox: false
        default: true
        }
    }
}

// MARK: - State

/// What's in the bar, where it's docked and whether it's collapsed: the same in every editor, and saved
/// across launches.
@MainActor
final class ToolPickerState: ObservableObject {
    @Published var items: ToolPickerItems {
        didSet { items.save(to: defaults) }
    }

    @Published var dock: ToolPickerDock {
        didSet { defaults.set(dock.rawValue, forKey: ToolPickerDock.defaultsKey) }
    }

    @Published var isCollapsed: Bool {
        didSet { defaults.set(isCollapsed, forKey: Self.collapsedKey) }
    }

    private let defaults: UserDefaults
    private static let collapsedKey = "InkKit.ToolPicker.collapsed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = ToolPickerItems.load(from: defaults)
        dock = defaults.string(forKey: ToolPickerDock.defaultsKey).flatMap(ToolPickerDock.init(rawValue:)) ?? .bottom
        isCollapsed = defaults.bool(forKey: Self.collapsedKey)
    }

    /// The slot that shows as selected for the canvas's current tool and brush.
    func selected(in controller: CanvasController) -> PickerTool? {
        PickerTool.current(tool: controller.tool, brushID: controller.brush(for: controller.tool).id, inBar: items.tools)
    }

    /// Selects `item`'s tool, with its brush. The ruler shows or hides instead.
    func activate(_ item: PickerTool, in controller: CanvasController) {
        if item == .ruler {
            controller.rulerVisible.toggle()
            return
        }
        guard let tool = item.tool else { return }
        if let id = item.brushID, let brush = controller.availableBrushes(for: tool).first(where: { $0.id == id }) {
            controller.selectBrush(brush, for: tool)
        }
        controller.select(tool)
    }
}

// MARK: - The bar

/// Figma **ToolPicker/Bar**: the floating tool picker. A 52 pt capsule of tool artwork, Plus, the colour
/// well, undo, redo and collapse. Docked at bottom centre by default; drag it by an empty part to snap it to
/// a lower corner, the top or a side edge (where it runs vertically). Once it would outgrow its edge the tool
/// row scrolls, fading at any edge with hidden tools. Collapse leaves a 52 pt circle showing the current tool
/// and ink.
///
/// Tap the selected tool again for colour & thickness (or its options); touch and hold a tool to move or
/// remove it; Plus adds tools that aren't in the bar.
struct ToolPicker: View {
    @ObservedObject var controller: CanvasController
    @ObservedObject var state: ToolPickerState
    /// The area the bar floats in: inside the safe area and below the navigation row.
    let bounds: CGSize

    @State private var dragTranslation: CGSize = .zero
    @State private var optionsItem: PickerTool?
    @State private var showAddTools = false
    @State private var showColorPicker = false
    @State private var rowOffset: CGFloat = 0
    @Environment(\.inkTheme) private var theme

    private typealias Layout = ToolPickerLayout

    var body: some View {
        let count = state.items.tools.count
        let length = Layout.barLength(count: count, maxLength: maxLength)
        let center = state.isCollapsed
            ? Layout.collapsedCenter(on: state.dock, length: length, in: bounds)
            : Layout.center(on: state.dock, length: length, in: bounds)
        Group {
            if state.isCollapsed {
                collapsed
            } else {
                bar
            }
        }
        .position(x: center.x + dragTranslation.width, y: center.y + dragTranslation.height)
        .frame(width: bounds.width, height: bounds.height)
    }

    private var maxLength: CGFloat {
        Layout.maxLength(on: state.dock, in: bounds)
    }

    private var isVertical: Bool {
        state.dock.isVertical
    }

    /// The arrow edge for popovers: they open away from the edge the bar is docked on.
    private var popoverEdge: Edge {
        switch state.dock {
        case .bottom, .bottomLeading, .bottomTrailing: .bottom
        case .top: .top
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    // MARK: Bar

    private var bar: some View {
        let stack = isVertical
            ? AnyLayout(VStackLayout(spacing: Layout.gap))
            : AnyLayout(HStackLayout(spacing: Layout.gap))
        return stack {
            toolRow
            plusButton
            divider
            colorWell
            divider
            Button { controller.undo() } label: { InkIconView(.undo, size: 22).frame(width: Layout.slot, height: Layout.slot) }
                .buttonStyle(ToolPickerButtonStyle())
                .disabled(!controller.canUndo)
                .accessibilityLabel("Undo")
            Button { controller.redo() } label: { InkIconView(.redo, size: 22).frame(width: Layout.slot, height: Layout.slot) }
                .buttonStyle(ToolPickerButtonStyle())
                .disabled(!controller.canRedo)
                .accessibilityLabel("Redo")
            Button {
                withAnimation(.snappy) { state.isCollapsed = true }
            } label: {
                InkIconView(.disclosure, size: 16)
                    .rotationEffect(collapseRotation)
                    .frame(width: Layout.slot, height: Layout.slot)
            }
            .buttonStyle(ToolPickerButtonStyle())
            .accessibilityLabel("Collapse Tools")
        }
        .padding(isVertical ? .top : .leading, Layout.leadingPadding)
        .padding(isVertical ? .bottom : .trailing, Layout.trailingPadding)
        .padding(isVertical ? .horizontal : .vertical, (Layout.thickness - Layout.slot) / 2)
        .background {
            // Empty parts of the bar are its handle.
            Color.clear.contentShape(Rectangle()).gesture(dragGesture)
        }
        .inkFloatingMaterial(in: RoundedRectangle(cornerRadius: Layout.thickness / 2, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    /// The chevron points at the edge the bar collapses towards: down along the bottom, and so on.
    private var collapseRotation: Angle {
        switch state.dock {
        case .bottom, .bottomLeading, .bottomTrailing: .zero
        case .top: .degrees(180)
        case .leading: .degrees(90)
        case .trailing: .degrees(-90)
        }
    }

    private var divider: some View {
        Capsule()
            .fill(theme.color(\.separator))
            .frame(width: isVertical ? 24 : Layout.divider, height: isVertical ? Layout.divider : 24)
            .accessibilityHidden(true)
    }

    // MARK: Tool row

    @ViewBuilder
    private var toolRow: some View {
        let tools = state.items.tools
        let overflows = Layout.overflows(count: tools.count, maxLength: maxLength)
        let stack = isVertical
            ? AnyLayout(VStackLayout(spacing: Layout.gap))
            : AnyLayout(HStackLayout(spacing: Layout.gap))
        let row = stack {
            ForEach(tools) { item in
                slot(for: item)
            }
        }
        if overflows {
            let viewport = Layout.viewportLength(count: tools.count, maxLength: maxLength)
            let hidden = Layout.rowLength(count: tools.count) - viewport
            ScrollViewReader { proxy in
                ScrollView(isVertical ? .vertical : .horizontal, showsIndicators: false) {
                    row.background {
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(Self.rowSpace))
                            Color.clear.preference(key: RowOffsetKey.self, value: isVertical ? -frame.minY : -frame.minX)
                        }
                    }
                }
                .coordinateSpace(name: Self.rowSpace)
                .onPreferenceChange(RowOffsetKey.self) { rowOffset = $0 }
                .onAppear {
                    if let selected = state.selected(in: controller) {
                        proxy.scrollTo(selected, anchor: .center)
                    }
                }
            }
            .frame(width: isVertical ? Layout.slot : viewport, height: isVertical ? viewport : Layout.slot)
            .mask(fadeMask(leading: rowOffset > 1, trailing: rowOffset < hidden - 1))
        } else {
            row
        }
    }

    private static let rowSpace = "ToolPicker.row"

    /// Opaque in the middle, fading over 24 pt at each end that has tools scrolled out of sight.
    private func fadeMask(leading: Bool, trailing: Bool) -> some View {
        let stack = isVertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let start: UnitPoint = isVertical ? .top : .leading
        let end: UnitPoint = isVertical ? .bottom : .trailing
        let fade = Layout.fade
        return stack {
            if leading {
                LinearGradient(colors: [.clear, .black], startPoint: start, endPoint: end)
                    .frame(width: isVertical ? nil : fade, height: isVertical ? fade : nil)
            }
            Color.black
            if trailing {
                LinearGradient(colors: [.black, .clear], startPoint: start, endPoint: end)
                    .frame(width: isVertical ? nil : fade, height: isVertical ? fade : nil)
            }
        }
    }

    @ViewBuilder
    private func slot(for item: PickerTool) -> some View {
        let selected = item == .ruler ? controller.rulerVisible : state.selected(in: controller) == item
        Group {
            if item == .insert {
                InsertMenu(controller: controller, label: AnyView(ToolArtView(item: item, isSelected: false)
                        .frame(width: Layout.slot, height: Layout.slot)
                        .contentShape(Rectangle())))
                    .accessibilityLabel(item.title)
            } else {
                ToolSlot(item: item, isSelected: selected) {
                    if selected, item != .ruler {
                        optionsItem = item
                    } else {
                        state.activate(item, in: controller)
                    }
                }
                .popover(isPresented: optionsBinding(for: item), arrowEdge: popoverEdge) {
                    if item.opensColorAndThickness, let tool = item.tool {
                        ColorThicknessPopover(controller: controller, tool: tool)
                    } else if let tool = item.tool {
                        ToolOptionsView(controller: controller, tool: tool)
                    }
                }
            }
        }
        .id(item)
        .contextMenu { arrangeMenu(for: item) }
    }

    @ViewBuilder
    private func arrangeMenu(for item: PickerTool) -> some View {
        let tools = state.items.tools
        let index = tools.firstIndex(of: item) ?? 0
        if item == .ruler {
            Picker("Ruler", selection: Binding(get: { controller.rulerMode }, set: { mode in
                controller.rulerMode = mode
                controller.rulerVisible = true
            })) {
                Label("Ruler", systemImage: "ruler").tag(Ruler.Mode.ruler)
                Label("Protractor", systemImage: "angle").tag(Ruler.Mode.protractor)
            }
        }
        Button { withAnimation(.snappy) { state.items.move(item, by: -1) } } label: {
            Label(isVertical ? "Move Up" : "Move Left", systemImage: isVertical ? "arrow.up" : "arrow.left")
        }
        .disabled(index == 0)
        Button { withAnimation(.snappy) { state.items.move(item, by: 1) } } label: {
            Label(isVertical ? "Move Down" : "Move Right", systemImage: isVertical ? "arrow.down" : "arrow.right")
        }
        .disabled(index == tools.count - 1)
        Button(role: .destructive) {
            withAnimation(.snappy) { state.items.remove(item) }
        } label: {
            Label("Remove from Toolbar", systemImage: "minus.circle")
        }
        .disabled(!state.items.canRemove(item))
    }

    private func optionsBinding(for item: PickerTool) -> Binding<Bool> {
        Binding(get: { optionsItem == item }, set: {
            if !$0, optionsItem == item {
                optionsItem = nil
            }
        })
    }

    // MARK: Plus and colour well

    private var plusButton: some View {
        Button { showAddTools = true } label: {
            InkIconView(.addPage, size: 20).frame(width: Layout.slot, height: Layout.slot)
        }
        .buttonStyle(ToolPickerButtonStyle())
        .accessibilityLabel("Add Tools")
        .popover(isPresented: $showAddTools, arrowEdge: popoverEdge) {
            AddToolsPopover(state: state)
        }
    }

    private var colorWell: some View {
        let tool = controller.tool
        let color = controller.color(for: tool)
        return Button { showColorPicker = true } label: {
            ZStack {
                Circle()
                    .strokeBorder(theme.color(\.textPrimary).opacity(0.18), lineWidth: 1.5)
                    .frame(width: 32, height: 32)
                Circle()
                    .fill(color.color)
                    .overlay(Circle().strokeBorder(theme.color(\.swatchOutline), lineWidth: 0.5))
                    .frame(width: 24, height: 24)
            }
            .frame(width: Layout.slot, height: Layout.slot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tool.usesInk)
        .opacity(tool.usesInk ? 1 : 0.35)
        .accessibilityLabel("Color")
        .accessibilityValue(controller.colorName(color, for: tool))
        .accessibilityHint("Opens the color picker.")
        .popover(isPresented: $showColorPicker, arrowEdge: popoverEdge) {
            ColorPickerView(controller: controller, tool: tool, quickColorIndex: nil) { showColorPicker = false }
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        let item = state.selected(in: controller) ?? state.items.tools.first ?? .pen
        let ink = controller.color(for: controller.tool)
        return ZStack(alignment: .topLeading) {
            ToolArtView(item: item, isSelected: false)
                .frame(width: 34, height: 34)
                .offset(x: 9, y: 9)
            if controller.tool.usesInk {
                ZStack {
                    Circle().fill(theme.color(\.paper)).frame(width: 16, height: 16)
                    Circle().fill(ink.color).frame(width: 12, height: 12)
                }
                .compositingGroup()
                .shadow(color: theme.color(\.shadow).opacity(0.20), radius: 1, y: 1)
                .offset(x: 33, y: 33)
            }
        }
        .frame(width: Layout.thickness, height: Layout.thickness, alignment: .topLeading)
        .contentShape(Circle())
        .inkFloatingMaterial(in: Circle())
        .onTapGesture {
            withAnimation(.snappy) { state.isCollapsed = false }
        }
        .gesture(dragGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tools")
        .accessibilityValue(Text(item.title))
        .accessibilityHint("Shows the tool picker.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { withAnimation(.snappy) { state.isCollapsed = false } }
    }

    // MARK: Dragging

    /// The bar follows the finger and, when let go, snaps to the nearest dock.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { dragTranslation = $0.translation }
            .onEnded { value in
                let count = state.items.tools.count
                let length = Layout.barLength(count: count, maxLength: maxLength)
                let start = state.isCollapsed
                    ? Layout.collapsedCenter(on: state.dock, length: length, in: bounds)
                    : Layout.center(on: state.dock, length: length, in: bounds)
                let dropped = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                let dock = Layout.nearestDock(to: dropped, count: count, in: bounds, collapsed: state.isCollapsed)
                withAnimation(.snappy) {
                    state.dock = dock
                    dragTranslation = .zero
                }
            }
    }
}

private struct RowOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A 44 pt glyph button in the bar: dims while pressed and when disabled.
private struct ToolPickerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolPickerButtonBody(configuration: configuration)
    }
}

private struct ToolPickerButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.inkTheme) private var theme

    var body: some View {
        configuration.label
            .foregroundStyle(theme.color(isEnabled ? \.textPrimary : \.textTertiary))
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Tool slot

/// Figma **ToolPicker/Tool**: a 44 pt slot with the tool's 34 pt artwork. Selected adds a 44 pt pill
/// behind it and lifts the artwork's shadow.
private struct ToolSlot: View {
    let item: PickerTool
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.color(\.selectionPill))
                        .shadow(color: theme.color(\.shadow).opacity(0.12), radius: 3, y: 2)
                        .shadow(color: theme.color(\.shadow).opacity(0.08), radius: 0.5)
                }
                ToolArtView(item: item, isSelected: isSelected)
            }
            .frame(width: ToolPickerLayout.slot, height: ToolPickerLayout.slot)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected && item != .ruler ? "Shows options for this tool." : "")
    }
}

/// A tool's artwork from the theme at 34 pt, or its glyph when the theme has none. The realistic tools cast
/// a small shadow, raised while selected.
struct ToolArtView: View {
    let item: PickerTool
    let isSelected: Bool
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Group {
            if let art = theme.toolArt(item) {
                art
            } else {
                InkIconView(item.glyph, size: 22)
                    .foregroundStyle(theme.color(\.textPrimary))
            }
        }
        .frame(width: 34, height: 34)
        .shadow(color: theme.color(\.shadow).opacity(item.castsShadow ? (isSelected ? 0.28 : 0.18) : 0),
                radius: isSelected ? 1.5 : 0.75, y: isSelected ? 2 : 1)
        .accessibilityHidden(true)
    }
}

// MARK: - Plus popover

/// Figma State 04: the tools that aren't in the bar, each with an Add button that appends it to the row.
private struct AddToolsPopover: View {
    @ObservedObject var state: ToolPickerState
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.m) {
            Text("Add Tools")
                .font(theme.headlineFont)
                .foregroundStyle(theme.color(\.textPrimary))
            let addable = state.items.addable
            if addable.isEmpty {
                Text("Every tool is already in the bar.")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.color(\.textSecondary))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(addable.enumerated()), id: \.element) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(theme.color(\.separator))
                                .frame(height: 0.5)
                                .padding(.leading, 48)
                        }
                        row(item)
                    }
                }
            }
            Text("Touch and hold a tool in the bar to rearrange it or remove it.")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(InkSpacing.l)
        .frame(width: 340)
        .presentationCompactAdaptation(.popover)
    }

    private func row(_ item: PickerTool) -> some View {
        HStack(spacing: InkSpacing.s) {
            ToolArtView(item: item, isSelected: false)
                .frame(width: ToolPickerLayout.slot, height: ToolPickerLayout.slot)
            Text(item.title)
                .font(.body)
                .foregroundStyle(theme.color(\.textPrimary))
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy) { state.items.add(item) }
            } label: {
                ZStack {
                    Circle().fill(theme.color(\.addTint)).frame(width: 26, height: 26)
                    InkIconView(.addPage, size: 14).foregroundStyle(theme.color(\.paper))
                }
                .frame(width: ToolPickerLayout.slot, height: ToolPickerLayout.slot)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Add \(Text(item.title))"))
        }
    }
}

// MARK: - Colour & thickness popover

/// Figma State 05: the tool's colours and a thickness slider with a live dot preview. Opens when the
/// selected drawing tool is tapped again.
struct ColorThicknessPopover: View {
    @ObservedObject var controller: CanvasController
    let tool: Tool
    @Environment(\.inkTheme) private var theme

    var body: some View {
        let colors = controller.quickColors(for: tool)
        let current = controller.color(for: tool)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                ForEach(colors, id: \.self) { color in
                    swatch(color, isSelected: color == current)
                }
            }
            Rectangle()
                .fill(theme.color(\.separator))
                .frame(height: 0.5)
            Text("Thickness")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
            HStack(spacing: InkSpacing.m) {
                Slider(value: thickness, in: 0 ... 1) { Text("Thickness") }
                    .tint(current.color)
                    .accessibilityValue(width.formatted(.number.precision(.fractionLength(1))) + " pt")
                Circle()
                    .fill(current.color)
                    .frame(width: ToolPickerLayout.previewDiameter(for: thickness.wrappedValue),
                           height: ToolPickerLayout.previewDiameter(for: thickness.wrappedValue))
                    .frame(width: ToolPickerLayout.slot, height: ToolPickerLayout.slot)
                    .accessibilityHidden(true)
            }
        }
        .padding(InkSpacing.l)
        .frame(width: 384)
        .presentationCompactAdaptation(.popover)
    }

    private func swatch(_ color: PenColor, isSelected: Bool) -> some View {
        Button { controller.setColor(color, for: tool) } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .strokeBorder(theme.color(\.textPrimary), lineWidth: 2.5)
                        .frame(width: 36, height: 36)
                }
                Circle()
                    .fill(color.color)
                    .overlay(Circle().strokeBorder(theme.color(\.swatchOutline), lineWidth: 1))
                    .frame(width: isSelected ? 24 : 28, height: isSelected ? 24 : 28)
            }
            .frame(width: ToolPickerLayout.slot, height: ToolPickerLayout.slot)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(controller.colorName(color, for: tool))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var width: Double {
        controller.settings[tool]?.width ?? controller.current.width
    }

    /// The width as 0…1 of the tool's range.
    private var thickness: Binding<Double> {
        let range = CanvasController.widthRange(for: tool)
        let span = range.upperBound - range.lowerBound
        return Binding {
            span > 0 ? (width - range.lowerBound) / span : 0
        } set: { value in
            var s = controller.settings[tool] ?? controller.current
            s.width = range.lowerBound + value * span
            controller.settings[tool] = s
        }
    }
}
