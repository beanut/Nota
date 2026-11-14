import SwiftUI

extension Tool {
    var icon: InkIcon {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .eraser: .eraser
        case .lasso: .lasso
        case .shape: .shapes
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        case .shape: "Shapes"
        }
    }

    /// Whether the tool draws in a colour picked from the Pen Case.
    var usesInk: Bool {
        switch self {
        case .pen, .pencil, .highlighter, .shape: true
        case .eraser, .lasso: false
        }
    }
}

/// The Pen Case: the one drawing toolbar. Pen tray · tools · colours · undo/redo · more, placed in the
/// navigation bar on the same row as the back button. The note's title and Rename live in the More menu.
/// Tap the selected tool again for its options, and the selected colour again to change it.
struct PenCase: View {
    @ObservedObject var controller: CanvasController
    var title: Binding<String>?

    @State private var optionsTool: Tool?
    @State private var showPenTray = false
    @State private var showSettings = false
    @State private var showPencilSettings = false
    @State private var confirmClear = false
    @State private var showRename = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: InkSpacing.xxxs) {
            Button { showPenTray = true } label: { InkIconView(.penTray) }
                .buttonStyle(.inkIcon(selected: showPenTray))
                .accessibilityLabel("Pens")
                .accessibilityHint("Shows your saved pens.")
                .popover(isPresented: $showPenTray, arrowEdge: .top) {
                    PenTrayView(controller: controller)
                }
            InkBarDivider(axis: .horizontal)
            ViewThatFits(in: .horizontal) {
                tools
                ScrollView(.horizontal, showsIndicators: false) { tools }
            }
            InkBarDivider(axis: .horizontal)
            InkRow(controller: controller, axis: .horizontal, opensPicker: true)
            InkBarDivider(axis: .horizontal)
            Button { controller.undo() } label: { InkIconView(.undo) }
                .buttonStyle(.inkIcon)
                .disabled(!controller.canUndo)
                .accessibilityLabel("Undo")
            Button { controller.redo() } label: { InkIconView(.redo) }
                .buttonStyle(.inkIcon)
                .disabled(!controller.canRedo)
                .accessibilityLabel("Redo")
            InkBarDivider(axis: .horizontal)
            moreMenu
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    private var tools: some View {
        HStack(spacing: InkSpacing.xxxs) {
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool, selected: controller.tool == tool) {
                    if controller.tool == tool {
                        optionsTool = tool
                    } else {
                        controller.select(tool)
                    }
                }
                .popover(isPresented: optionsBinding(for: tool), arrowEdge: .top) {
                    ToolOptionsView(controller: controller, tool: tool)
                }
            }
        }
    }

    private func optionsBinding(for tool: Tool) -> Binding<Bool> {
        Binding(get: { optionsTool == tool }, set: {
            if !$0 {
                optionsTool = nil
            }
        })
    }

    private var moreMenu: some View {
        Menu {
            if let title {
                Section(title.wrappedValue.isEmpty ? "Untitled" : title.wrappedValue) {
                    Button {
                        draftTitle = title.wrappedValue
                        showRename = true
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                }
            }
            Button { controller.resetZoom() } label: {
                Label("Fit Page · \(Int((controller.zoom * 100).rounded()))%", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if controller.pageLayout == .paged || !controller.allowsContinuousLayout {
                Toggle(isOn: $controller.zoomWindowVisible) {
                    Label("Zoom Window", systemImage: "rectangle.and.text.magnifyingglass")
                }
            }
            if controller.allowsContinuousLayout {
                Picker(selection: $controller.pageLayout) {
                    ForEach(PageLayoutMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode == .paged ? "arrow.left.and.right" : "arrow.up.and.down")
                            .tag(mode)
                    }
                } label: {
                    Label("Scroll Direction", systemImage: "arrow.up.and.down.text.horizontal")
                }
                .pickerStyle(.menu)
            }
            Button { controller.insertPlaceholderObject() } label: {
                Label("Add Test Object", systemImage: "square.on.square.dashed")
            }
            Divider()
            Button { showSettings = true } label: {
                Label("Pressure & Tilt…", systemImage: "hand.draw")
            }
            Button { showPencilSettings = true } label: {
                Label("Apple Pencil…", systemImage: "applepencil")
            }
            Toggle(isOn: $controller.hudVisible) {
                Label("Debug HUD", systemImage: "gauge.with.dots.needle.67percent")
            }
            Toggle(isOn: Binding(get: { controller.isRecordingInput }, set: { controller.setRecordingInput($0) })) {
                Label("Record Pencil Input", systemImage: "record.circle")
            }
            if let url = controller.lastRecordingURL, !controller.isRecordingInput {
                ShareLink(item: url) {
                    Label("Share Pencil Recording…", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear Page", systemImage: "trash")
            }
            .disabled(!controller.canUndo && !controller.canRedo)
        } label: {
            InkIconView(.more)
        }
        .menuStyle(.button)
        .buttonStyle(.inkIcon)
        .accessibilityLabel("More")
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            CanvasSettingsView(controller: controller)
        }
        .popover(isPresented: $showPencilSettings, arrowEdge: .top) {
            PencilSettingsView(controller: controller)
        }
        .confirmationDialog("Clear the page?", isPresented: $confirmClear) {
            Button("Clear Page", role: .destructive) { controller.clear() }
        } message: {
            Text("You can undo this.")
        }
        .alert("Rename Note", isPresented: $showRename) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { title?.wrappedValue = draftTitle }
        }
    }
}

private struct ToolButton: View {
    let tool: Tool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            InkIconView(tool.icon)
        }
        .buttonStyle(.inkIcon(selected: selected))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "Shows options for this tool." : "")
    }
}

/// The current tool's quick colours. Tools that don't draw in a colour keep showing the pen's, dimmed, so
/// the bar doesn't change length as you switch tools. With `opensPicker` (the Pen Case), tapping the
/// selected colour again edits it in the colour picker, and a colour well after the swatches opens the
/// picker for any colour.
private struct InkRow: View {
    @ObservedObject var controller: CanvasController
    let axis: Axis
    var opensPicker = false
    var onPick: () -> Void = {}
    /// The open picker: a quick colour's index, or -1 for the colour well.
    @State private var pickerSlot: Int?

    var body: some View {
        let tool = controller.tool
        let colors = controller.quickColors(for: tool)
        let current = controller.color(for: tool)
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: InkSpacing.xxxs))
            : AnyLayout(VStackLayout(spacing: InkSpacing.xxxs))
        layout {
            ForEach(colors.indices, id: \.self) { i in
                let isSelected = tool.usesInk && current == colors[i]
                InkSwatchButton(color: colors[i], name: controller.colorName(colors[i], for: tool),
                                isSelected: isSelected) {
                    if opensPicker, isSelected {
                        pickerSlot = i
                    } else {
                        controller.setColor(colors[i], for: tool)
                        onPick()
                    }
                }
                .accessibilityHint(opensPicker && isSelected ? "Double-tap again to change this color." : "")
                .popover(isPresented: slotBinding(i), arrowEdge: .top) {
                    ColorPickerView(controller: controller, tool: tool, quickColorIndex: i) { pickerSlot = nil }
                }
            }
            if opensPicker {
                ColorWellButton(color: current, isSelected: tool.usesInk && !colors.contains(current)) {
                    pickerSlot = -1
                }
                .popover(isPresented: slotBinding(-1), arrowEdge: .top) {
                    ColorPickerView(controller: controller, tool: tool, quickColorIndex: nil) { pickerSlot = nil }
                }
            }
        }
        .padding(axis == .horizontal ? .horizontal : .vertical, InkSpacing.xs)
        .disabled(!tool.usesInk)
        .opacity(tool.usesInk ? 1 : 0.35)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Colors")
    }

    private func slotBinding(_ slot: Int) -> Binding<Bool> {
        Binding(get: { pickerSlot == slot }, set: {
            if !$0, pickerSlot == slot {
                pickerSlot = nil
            }
        })
    }
}

/// Figma **Tool Options**: brush picker, width presets and slider, eraser and lasso modes, delete
/// selection. Opens when the selected tool is tapped again.
struct ToolOptionsView: View {
    @ObservedObject var controller: CanvasController
    let tool: Tool
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.m) {
            Text(tool.title)
                .font(theme.headlineFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .padding(.top, InkSpacing.s)

            switch tool {
            case .eraser:
                EraserOptions(controller: controller) { widthControls }
            case .lasso:
                Picker("Shape", selection: $controller.lassoMode) {
                    Text("Freeform").tag(LassoMode.freeform)
                    Text("Rectangle").tag(LassoMode.square)
                }
                .pickerStyle(.segmented)
                Button {
                    controller.deleteSelection()
                } label: {
                    HStack(spacing: InkSpacing.xs) {
                        InkIconView(.delete, size: 16)
                        Text("Delete Selection")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkSecondaryButtonStyle())
                .disabled(!controller.hasSelection)
                if let style = controller.selectedShapeStyle {
                    ShapeStyleControls(
                        controller: controller,
                        lineStyle: Binding(get: { style.lineStyle },
                                           set: { new in controller.restyleSelectedShapes { $0.lineStyle = new } }),
                        fill: Binding(get: { style.fill }, set: { new in controller.restyleSelectedShapes { $0.fill = new } }),
                        color: Binding(get: { style.color }, set: { new in controller.restyleSelectedShapes { $0.color = new } })
                    )
                }
            case .shape:
                ShapeStyleControls(controller: controller, lineStyle: $controller.shapeLineStyle,
                                   fill: $controller.shapeFill, color: nil)
                Text("Draw a shape and it snaps to it. Anything else becomes a smooth curve.")
                    .font(theme.footnoteFont)
                    .foregroundStyle(theme.color(\.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                widthControls
            case .pen, .pencil, .highlighter:
                BrushPicker(controller: controller, tool: tool)
                Button {
                    controller.editBrush(for: tool)
                } label: {
                    Text(controller.isCustomBrush(controller.brush(for: tool), for: tool)
                        ? "Edit Brush…" : "Customize Brush…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkSecondaryButtonStyle())
                widthControls
            }
        }
        .padding(.horizontal, InkSpacing.l)
        .frame(width: 300)
        .inkPopoverContent()
    }

    @ViewBuilder
    private var widthControls: some View {
        let presets = controller.quickSizes(for: tool)
        let range = CanvasController.widthRange(for: tool)
        let width = Binding(get: { settings.width }, set: { setWidth($0) })
        HStack(spacing: InkSpacing.s) {
            ForEach(presets.indices, id: \.self) { i in
                let preset = presets[i]
                Button { setWidth(preset) } label: {
                    Circle()
                        .fill(dotColor)
                        .frame(width: CGFloat(6 + 5 * i), height: CGFloat(6 + 5 * i))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(abs(settings.width - preset) < 0.05 ? theme.color(\.surfaceSelected) : theme.color(\.surfaceFill),
                                    in: RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["Fine", "Medium", "Bold"][min(i, 2)])
                .accessibilityValue(preset.formatted(.number.precision(.fractionLength(1))) + " pt")
                .accessibilityAddTraits(abs(settings.width - preset) < 0.05 ? .isSelected : [])
                .contextMenu {
                    if tool.penKind != nil {
                        Button { controller.setQuickSize(at: i, for: tool) } label: {
                            Label("Use \(settings.width.formatted(.number.precision(.fractionLength(1)))) pt Here",
                                  systemImage: "arrow.down.to.line")
                        }
                        Button { controller.resetQuickSizes(for: tool) } label: {
                            Label("Reset Sizes", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
        }
        if tool.penKind != nil {
            Text("Touch and hold a size to keep the current width there.")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        InkSliderRow("Width", value: width, in: range,
                     valueText: settings.width.formatted(.number.precision(.fractionLength(1))) + " pt")
    }

    private var settings: CanvasController.ToolSettings {
        controller.settings[tool] ?? controller.current
    }

    private func setWidth(_ width: Double) {
        var s = settings
        s.width = width
        controller.settings[tool] = s
    }

    private var dotColor: Color {
        guard tool.usesInk else { return theme.color(\.textSecondary) }
        return controller.color(for: tool).color
    }
}

/// A shape's line style and fill, and with `color` its outline colour: the shape tool's options for new
/// shapes, or the lasso's for the selected ones.
private struct ShapeStyleControls: View {
    @ObservedObject var controller: CanvasController
    @Binding var lineStyle: ShapeObject.LineStyle
    @Binding var fill: PenColor?
    /// The outline colour, when it's edited here (selected shapes); the shape tool takes it from the Pen Case.
    var color: Binding<PenColor>?
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.s) {
            Picker("Line", selection: $lineStyle) {
                Text("Solid").tag(ShapeObject.LineStyle.solid)
                Text("Dashed").tag(ShapeObject.LineStyle.dashed)
                Text("Dotted").tag(ShapeObject.LineStyle.dotted)
            }
            .pickerStyle(.segmented)
            if let color {
                swatchRow("Color") {
                    ForEach(colors, id: \.self) { c in
                        InkSwatchButton(color: c, name: controller.colorName(c, for: .shape),
                                        isSelected: color.wrappedValue == c) { color.wrappedValue = c }
                    }
                }
            }
            swatchRow("Fill") {
                Button { fill = nil } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(theme.color(\.textSecondary), lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                        Rectangle()
                            .fill(theme.color(\.textSecondary))
                            .frame(width: 1.5, height: 22)
                            .rotationEffect(.degrees(45))
                        if fill == nil {
                            Circle().strokeBorder(theme.color(\.textPrimary), lineWidth: 2)
                        }
                    }
                    .frame(width: InkMetrics.swatch, height: InkMetrics.swatch)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("No Fill")
                .accessibilityAddTraits(fill == nil ? .isSelected : [])
                ForEach(colors, id: \.self) { c in
                    InkSwatchButton(color: c, name: controller.colorName(c, for: .shape), isSelected: fill == c) {
                        fill = c
                    }
                }
            }
        }
    }

    private var colors: [PenColor] {
        controller.quickColors(for: .shape)
    }

    private func swatchRow(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: InkSpacing.xxxs) {
            Text(title)
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textPrimary))
            Spacer(minLength: InkSpacing.s)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The eraser's options: mode, size (`sizes`), which ink it erases, switching back afterwards, and
/// Clear Page.
private struct EraserOptions<Sizes: View>: View {
    @ObservedObject var controller: CanvasController
    @ViewBuilder let sizes: () -> Sizes
    @State private var confirmClear = false
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Picker("Mode", selection: $controller.eraserMode) {
            Text("Precision").tag(EraserMode.precision)
            Text("Standard").tag(EraserMode.standard)
            Text("Stroke").tag(EraserMode.stroke)
        }
        .pickerStyle(.segmented)
        Text(modeDescription)
            .font(theme.footnoteFont)
            .foregroundStyle(theme.color(\.textSecondary))
            .fixedSize(horizontal: false, vertical: true)

        sizes()

        VStack(alignment: .leading, spacing: InkSpacing.xxs) {
            Picker("Erase", selection: $controller.eraserTarget) {
                Text("All Ink").tag(EraserTarget.all)
                Text("Highlighter").tag(EraserTarget.highlighter)
                Text("Pencil").tag(EraserTarget.pencil)
            }
            .pickerStyle(.segmented)
            .disabled(!controller.eraserMode.canTarget)
            Text(controller.eraserMode.canTarget
                ? "Highlighter or Pencil leaves every other kind of ink alone."
                : "Precision erases all ink. Use Standard or Stroke to erase only highlighter or pencil.")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }

        Toggle("Switch back after erasing", isOn: $controller.switchBackAfterErasing)
            .font(theme.bodyFont)
            .foregroundStyle(theme.color(\.textPrimary))
            .tint(theme.color(\.accent))

        Button(role: .destructive) { confirmClear = true } label: {
            HStack(spacing: InkSpacing.xs) {
                InkIconView(.delete, size: 16)
                Text("Clear Page")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(InkSecondaryButtonStyle())
        .disabled(!controller.canUndo && !controller.canRedo)
        .confirmationDialog("Clear the page?", isPresented: $confirmClear) {
            Button("Clear Page", role: .destructive) { controller.clear() }
        } message: {
            Text("You can undo this.")
        }
        .padding(.bottom, InkSpacing.s)
    }

    private var modeDescription: LocalizedStringKey {
        switch controller.eraserMode {
        case .precision: "Erases exactly what's under it."
        case .standard: "Erases the parts of strokes it passes over."
        case .stroke: "Erases whole strokes."
        }
    }
}

/// Pressure response, tilt toggle and HUD toggle.
struct CanvasSettingsView: View {
    @ObservedObject var controller: CanvasController
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.l) {
            Text("Pressure & Tilt")
                .font(theme.headlineFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .padding(.top, InkSpacing.s)

            InkSliderRow("Minimum width", value: $controller.minWidthRatio, in: 0.02 ... 1,
                         valueText: "\(Int(controller.minWidthRatio * 100))% of max")

            VStack(alignment: .leading, spacing: InkSpacing.xxs) {
                InkSliderRow("Response curve", value: $controller.pressureGamma, in: 0.25 ... 3,
                             valueText: String(format: "γ = %.2f", controller.pressureGamma))
                CurvePreview(gamma: controller.pressureGamma, minRatio: controller.minWidthRatio)
                    .frame(height: 80)
                Text("γ < 1 boosts light pressure, γ > 1 needs a firmer press.")
                    .font(theme.footnoteFont)
                    .foregroundStyle(theme.color(\.textSecondary))
            }

            Toggle("Tilt shading (wider + lighter when tilted)", isOn: $controller.tiltEnabled)
            Toggle("Debug HUD", isOn: $controller.hudVisible)

            #if targetEnvironment(simulator)
                VStack(alignment: .leading, spacing: InkSpacing.xxs) {
                    InkSliderRow("Simulated altitude", value: $controller.simulatedAltitudeDegrees, in: 5 ... 90,
                                 valueText: "\(Int(controller.simulatedAltitudeDegrees))°")
                    Text("Simulator only. Lower it to try tilt shading without a Pencil.")
                        .font(theme.footnoteFont)
                        .foregroundStyle(theme.color(\.textSecondary))
                }
            #endif
        }
        .font(theme.bodyFont)
        .foregroundStyle(theme.color(\.textPrimary))
        .tint(theme.color(\.accent))
        .padding(.horizontal, InkSpacing.xl)
        .padding(.bottom, InkSpacing.s)
        .frame(width: 340)
        .inkPopoverContent()
    }
}

/// Width (y) as a function of pressure (x).
private struct CurvePreview: View {
    let gamma: Double
    let minRatio: Double
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Canvas { ctx, size in
            var frame = Path()
            frame.addRect(CGRect(origin: .zero, size: size))
            ctx.stroke(frame, with: .color(theme.color(\.separator)))
            var curve = Path()
            for i in 0 ... 60 {
                let x = Double(i) / 60
                let y = minRatio + (1 - minRatio) * pow(x, gamma)
                let p = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                if i == 0 {
                    curve.move(to: p)
                } else {
                    curve.addLine(to: p)
                }
            }
            ctx.stroke(curve, with: .color(theme.color(\.accent)), lineWidth: 2)
        }
    }
}

/// The quick palette a Pencil squeeze or double-tap shows at the Pencil: tools and inks only. It sits
/// above the tip, on the side away from the writing hand.
struct QuickPaletteView: View {
    @ObservedObject var controller: CanvasController
    let location: CGPoint
    @State private var paletteSize = CGSize(width: 420, height: 52)

    var body: some View {
        GeometryReader { geo in
            palette(center: PencilSettings.paletteCenter(anchor: location, size: paletteSize,
                                                         in: CGRect(origin: .zero, size: geo.size),
                                                         handedness: controller.pencilSettings.handedness))
        }
    }

    private func palette(center: CGPoint) -> some View {
        ZStack {
            Color.black.opacity(0.001) // tap anywhere to dismiss
                .onTapGesture { controller.quickPaletteLocation = nil }
            HStack(spacing: InkSpacing.xxxs) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(tool: tool, selected: controller.tool == tool) {
                        controller.select(tool)
                        controller.quickPaletteLocation = nil
                    }
                }
                InkBarDivider()
                InkRow(controller: controller, axis: .horizontal) { controller.quickPaletteLocation = nil }
            }
            .padding(InkSpacing.xxs)
            .inkFloatingBar()
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { paletteSize = $0 }
            .position(center)
        }
    }
}

/// The zoom window's buttons, in a column at the right of its writing panel: close, then move the box
/// back, on, or to the start of the next line.
struct ZoomWindowControls: View {
    @ObservedObject var controller: CanvasController

    var body: some View {
        VStack(spacing: InkSpacing.xxxs) {
            Button { controller.zoomWindowVisible = false } label: { InkIconView(.close) }
                .accessibilityLabel("Close zoom window")
            Spacer(minLength: 0)
            Button { controller.zoomWindowBack() } label: { InkIconView(.previousPage) }
                .disabled(!controller.zoomCanGoBack)
                .accessibilityLabel("Move zoom box back")
            Button { controller.zoomWindowAdvance() } label: { InkIconView(.nextPage) }
                .accessibilityLabel("Move zoom box on")
            Button { controller.zoomWindowNewLine() } label: { InkIconView(.newLine) }
                .accessibilityLabel("Next line")
        }
        .buttonStyle(.inkIcon)
        .padding(.vertical, InkSpacing.xs)
    }
}
