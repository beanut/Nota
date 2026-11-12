import NotaUI
import SwiftUI

/// An edge of the editor the Pen Case can be docked to.
public enum ToolbarDock: String, CaseIterable, Identifiable, Sendable {
    case top, bottom, leading, trailing

    public var id: String {
        rawValue
    }

    /// The direction the bar's items run in.
    var axis: Axis {
        switch self {
        case .top, .bottom: .horizontal
        case .leading, .trailing: .vertical
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .leading: "Left"
        case .trailing: "Right"
        }
    }

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// The edge a popover's arrow points at: popovers open away from the docked edge.
    var popoverArrowEdge: Edge {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// The edge nearest to `point` in a container of `size`.
    static func nearest(to point: CGPoint, in size: CGSize) -> ToolbarDock {
        let distances: [(ToolbarDock, CGFloat)] = [
            (.top, point.y), (.bottom, size.height - point.y),
            (.leading, point.x), (.trailing, size.width - point.x)
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .top
    }
}

extension Tool {
    var icon: NotaIcon {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .eraser: .eraser
        case .lasso: .lasso
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    /// Whether the tool draws in a colour picked from the Pen Case.
    var usesInk: Bool {
        switch self {
        case .pen, .pencil, .highlighter: true
        case .eraser, .lasso: false
        }
    }
}

/// Figma **Floating Pen Case**: the one drawing toolbar. Tools · inks · undo/redo · more, floating over the
/// canvas and docked to any edge. Tap the selected tool again for its options; drag the grip to move the
/// bar to another edge.
struct PenCase: View {
    @ObservedObject var controller: CanvasController
    let dock: ToolbarDock
    /// Moves the bar to another edge.
    let onDock: (ToolbarDock) -> Void
    /// Called when the grip is dropped, with the drop point in the editor's coordinate space.
    let onDrop: (CGPoint) -> Void

    @State private var optionsTool: Tool?
    @State private var showSettings = false
    @State private var confirmClear = false
    @State private var dragOffset: CGSize = .zero

    static let coordinateSpace = "InkKit.editor"

    var body: some View {
        let axis = dock.axis
        stack(axis) {
            grip
            ViewThatFits(in: axis == .horizontal ? .horizontal : .vertical) {
                tools(axis)
                ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) { tools(axis) }
            }
            NotaBarDivider(in: axis)
            InkRow(controller: controller, axis: axis)
            NotaBarDivider(in: axis)
            Button { controller.undo() } label: { NotaIconView(.undo) }
                .buttonStyle(.notaIcon)
                .disabled(!controller.canUndo)
                .accessibilityLabel("Undo")
            Button { controller.redo() } label: { NotaIconView(.redo) }
                .buttonStyle(.notaIcon)
                .disabled(!controller.canRedo)
                .accessibilityLabel("Redo")
            NotaBarDivider(in: axis)
            moreMenu
        }
        .padding(NotaSpacing.xxs)
        .notaFloatingBar()
        .offset(dragOffset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    private func stack(_ axis: Axis, @ViewBuilder content: () -> some View) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: NotaSpacing.xxxs))
            : AnyLayout(VStackLayout(spacing: NotaSpacing.xxxs))
        return layout(content)
    }

    private func tools(_ axis: Axis) -> some View {
        stack(axis) {
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool, selected: controller.tool == tool) {
                    if controller.tool == tool {
                        optionsTool = tool
                    } else {
                        controller.select(tool)
                    }
                }
                .popover(isPresented: optionsBinding(for: tool), arrowEdge: dock.popoverArrowEdge) {
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

    /// Drag handle. Dropping it nearer another edge docks the bar there.
    private var grip: some View {
        NotaIconView(.grip)
            .rotationEffect(dock.axis == .horizontal ? .zero : .degrees(90))
            .foregroundStyle(NotaColor.textTertiary)
            .frame(width: dock.axis == .horizontal ? 20 : NotaSize.iconButton.width,
                   height: dock.axis == .horizontal ? NotaSize.iconButton.height : 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { value in
                        withAnimation(.snappy) {
                            dragOffset = .zero
                            onDrop(value.location)
                        }
                    }
            )
            .accessibilityLabel("Move toolbar")
            .accessibilityHint("Drag to another edge of the screen.")
    }

    private var moreMenu: some View {
        Menu {
            Button { controller.resetZoom() } label: {
                Label("Fit Page · \(Int((controller.zoom * 100).rounded()))%", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Picker(selection: Binding(get: { dock }, set: onDock)) {
                ForEach(ToolbarDock.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Move Toolbar", systemImage: "rectangle.3.group")
            }
            .pickerStyle(.menu)
            Divider()
            Button { showSettings = true } label: {
                Label("Pressure & Tilt…", systemImage: "hand.draw")
            }
            Toggle(isOn: $controller.hudVisible) {
                Label("Debug HUD", systemImage: "gauge.with.dots.needle.67percent")
            }
            Divider()
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear Page", systemImage: "trash")
            }
            .disabled(!controller.canUndo && !controller.canRedo)
        } label: {
            NotaIconView(.ellipsis)
        }
        .menuStyle(.button)
        .buttonStyle(.notaIcon)
        .accessibilityLabel("More")
        .popover(isPresented: $showSettings, arrowEdge: dock.popoverArrowEdge) {
            CanvasSettingsView(controller: controller)
        }
        .confirmationDialog("Clear the page?", isPresented: $confirmClear) {
            Button("Clear Page", role: .destructive) { controller.clear() }
        } message: {
            Text("You can undo this.")
        }
    }
}

private struct ToolButton: View {
    let tool: Tool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NotaIconView(tool.icon)
        }
        .buttonStyle(.notaIcon(selected: selected))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "Shows options for this tool." : "")
    }
}

/// The current tool's colour presets. Tools that don't draw in a colour keep showing the pen inks, dimmed,
/// so the bar doesn't change length as you switch tools.
private struct InkRow: View {
    @ObservedObject var controller: CanvasController
    let axis: Axis
    var onPick: () -> Void = {}

    var body: some View {
        let tool = controller.tool
        let inks = CanvasController.inks(for: tool.usesInk ? tool : .pen)
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: NotaSpacing.xxxs))
            : AnyLayout(VStackLayout(spacing: NotaSpacing.xxxs))
        layout {
            ForEach(inks.indices, id: \.self) { i in
                InkSwatch(inks[i], isSelected: tool.usesInk && controller.current.colorIndex == i) {
                    controller.current.colorIndex = i
                    onPick()
                }
            }
        }
        .padding(axis == .horizontal ? .horizontal : .vertical, NotaSpacing.xs)
        .disabled(!tool.usesInk)
        .opacity(tool.usesInk ? 1 : 0.35)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Colors")
    }
}

/// Figma **Tool Options**: width presets and slider, eraser and lasso modes, delete selection. Opens when
/// the selected tool is tapped again.
struct ToolOptionsView: View {
    @ObservedObject var controller: CanvasController
    let tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: NotaSpacing.m) {
            Text(tool.title)
                .font(NotaFont.headline)
                .foregroundStyle(NotaColor.textPrimary)
                .padding(.top, NotaSpacing.s)

            switch tool {
            case .eraser:
                Picker("Erase", selection: $controller.eraserMode) {
                    Text("Whole Stroke").tag(EraserMode.stroke)
                    Text("Pixel").tag(EraserMode.pixel)
                }
                .pickerStyle(.segmented)
                widthControls
            case .lasso:
                Picker("Shape", selection: $controller.lassoMode) {
                    Text("Freeform").tag(LassoMode.freeform)
                    Text("Rectangle").tag(LassoMode.square)
                }
                .pickerStyle(.segmented)
                Button {
                    controller.deleteSelection()
                } label: {
                    NotaButtonLabel("Delete Selection", icon: .trash, size: .compact)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.nota(.secondary, size: .compact))
                .disabled(!controller.hasSelection)
            case .pen, .pencil, .highlighter:
                widthControls
            }
        }
        .padding(.horizontal, NotaSpacing.l)
        .frame(width: 300)
        .notaPopoverContent()
    }

    @ViewBuilder
    private var widthControls: some View {
        let presets = CanvasController.widthPresets(for: tool)
        let range = CanvasController.widthRange(for: tool)
        let width = Binding(get: { settings.width }, set: { setWidth($0) })
        HStack(spacing: NotaSpacing.s) {
            ForEach(presets.indices, id: \.self) { i in
                let preset = presets[i]
                Button { setWidth(preset) } label: {
                    Circle()
                        .fill(dotColor)
                        .frame(width: CGFloat(6 + 5 * i), height: CGFloat(6 + 5 * i))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(abs(settings.width - preset) < 0.05 ? NotaColor.bgInkTint : NotaColor.bgFill,
                                    in: RoundedRectangle(cornerRadius: NotaRadius.control, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["Fine", "Medium", "Bold"][min(i, 2)])
                .accessibilityAddTraits(abs(settings.width - preset) < 0.05 ? .isSelected : [])
            }
        }
        NotaSliderRow("Width", value: width, in: range,
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
        guard tool.usesInk else { return NotaColor.textSecondary }
        let inks = CanvasController.inks(for: tool)
        return inks[min(max(settings.colorIndex, 0), inks.count - 1)].color
    }
}

/// Pressure response, tilt toggle and HUD toggle.
struct CanvasSettingsView: View {
    @ObservedObject var controller: CanvasController

    var body: some View {
        VStack(alignment: .leading, spacing: NotaSpacing.l) {
            Text("Pressure & Tilt")
                .font(NotaFont.headline)
                .foregroundStyle(NotaColor.textPrimary)
                .padding(.top, NotaSpacing.s)

            NotaSliderRow("Minimum width", value: $controller.minWidthRatio, in: 0.02 ... 1,
                          valueText: "\(Int(controller.minWidthRatio * 100))% of max")

            VStack(alignment: .leading, spacing: NotaSpacing.xxs) {
                NotaSliderRow("Response curve", value: $controller.pressureGamma, in: 0.25 ... 3,
                              valueText: String(format: "γ = %.2f", controller.pressureGamma))
                CurvePreview(gamma: controller.pressureGamma, minRatio: controller.minWidthRatio)
                    .frame(height: 80)
                Text("γ < 1 boosts light pressure, γ > 1 needs a firmer press.")
                    .font(NotaFont.footnote)
                    .foregroundStyle(NotaColor.textSecondary)
            }

            Toggle("Tilt shading (wider + lighter when tilted)", isOn: $controller.tiltEnabled)
            Toggle("Debug HUD", isOn: $controller.hudVisible)

            #if targetEnvironment(simulator)
                VStack(alignment: .leading, spacing: NotaSpacing.xxs) {
                    NotaSliderRow("Simulated altitude", value: $controller.simulatedAltitudeDegrees, in: 5 ... 90,
                                  valueText: "\(Int(controller.simulatedAltitudeDegrees))°")
                    Text("Simulator only. Lower it to try tilt shading without a Pencil.")
                        .font(NotaFont.footnote)
                        .foregroundStyle(NotaColor.textSecondary)
                }
            #endif
        }
        .font(NotaFont.subheadline)
        .foregroundStyle(NotaColor.textPrimary)
        .tint(NotaColor.accentInk)
        .padding(.horizontal, NotaSpacing.xl)
        .padding(.bottom, NotaSpacing.s)
        .frame(width: 340)
        .notaPopoverContent()
    }
}

/// Width (y) as a function of pressure (x).
private struct CurvePreview: View {
    let gamma: Double
    let minRatio: Double

    var body: some View {
        Canvas { ctx, size in
            var frame = Path()
            frame.addRect(CGRect(origin: .zero, size: size))
            ctx.stroke(frame, with: .color(NotaColor.borderSeparator))
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
            ctx.stroke(curve, with: .color(NotaColor.accentInk), lineWidth: 2)
        }
    }
}

/// Pencil Pro squeeze palette, shown at the hover location: tools and inks only.
struct QuickPaletteView: View {
    @ObservedObject var controller: CanvasController
    let location: CGPoint

    var body: some View {
        ZStack {
            Color.black.opacity(0.001) // tap anywhere to dismiss
                .onTapGesture { controller.quickPaletteLocation = nil }
            HStack(spacing: NotaSpacing.xxxs) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(tool: tool, selected: controller.tool == tool) {
                        controller.select(tool)
                        controller.quickPaletteLocation = nil
                    }
                }
                NotaBarDivider()
                InkRow(controller: controller, axis: .horizontal) { controller.quickPaletteLocation = nil }
            }
            .padding(NotaSpacing.xxs)
            .notaFloatingBar()
            .position(x: location.x, y: max(40, location.y - 60))
        }
    }
}
