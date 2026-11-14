import SwiftUI

/// The brush editor: every `BrushDescriptor` parameter as a slider, toggle or picker, over a live preview
/// drawn by the engine in the tool's colour with the Pressure & Tilt settings applied.
///
/// Done saves the brush and makes the tool draw with it: a brush the user made is changed in place, and
/// editing a built-in brush makes a new one of the user's own (`CanvasController.saveEditedBrush`). It's
/// also the manual-edit surface for brushes a model makes, since it shows and clamps every parameter.
struct BrushEditorView: View {
    @ObservedObject var controller: CanvasController
    let tool: Tool
    @State private var draft: BrushDescriptor
    private let original: BrushDescriptor
    @State private var savesAsPen = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inkTheme) private var theme
    @Environment(\.displayScale) private var displayScale

    init(controller: CanvasController, tool: Tool) {
        self.controller = controller
        self.tool = tool
        let brush = controller.brush(for: tool)
        var start = brush
        // The editor starts from the width the tool draws at, so the preview matches the page.
        if let width = controller.settings[tool]?.width {
            start = brush.sized(CGFloat(width), minimumRatio: brush.maxWidth > 0 ? brush.size.lowerBound / brush.maxWidth : 1)
        }
        original = start
        _draft = State(initialValue: start)
    }

    private var isCustom: Bool {
        controller.isCustomBrush(original, for: tool)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InkSpacing.xl) {
                    preview
                    nameField
                    ForEach(BrushParameter.Section.allCases) { section in
                        sectionView(section)
                    }
                    Toggle("Also save as a pen in the pen tray", isOn: $savesAsPen)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.color(\.textPrimary))
                        .tint(theme.color(\.accent))
                }
                .padding(InkSpacing.xl)
            }
            .background(theme.color(\.surfaceRaised))
            .navigationTitle(isCustom ? "Edit Brush" : "New Brush from \(original.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") { draft = original }
                        .disabled(draft == original)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(theme.color(\.accent))
    }

    // MARK: Parts

    /// The sample stroke at the brush's own width, as the tool would draw it.
    private var preview: some View {
        let shown = draft.personalized(width: draft.maxWidth, minimumWidthRatio: CGFloat(controller.minWidthRatio),
                                       pressureExponent: CGFloat(controller.pressureGamma),
                                       tilt: controller.tiltEnabled)
        let size = InkMetrics.brushEditorPreview
        return Group {
            if let image = BrushPreview.image(of: shown, color: controller.color(for: tool).rgba, scale: displayScale,
                                              size: size, fits: false) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .background(theme.color(\.paper), in: RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous)
            .strokeBorder(theme.color(\.border), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("Preview of \(draft.name)")
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: InkSpacing.xs) {
            sectionTitle("Name")
            TextField("Brush name", text: Binding(get: { draft.name }, set: {
                draft.name = String($0.prefix(BrushDescriptor.maxNameLength))
            }))
            .font(theme.bodyFont)
            .foregroundStyle(theme.color(\.textPrimary))
            .padding(.horizontal, InkSpacing.s)
            .frame(height: InkMetrics.iconButton.height)
            .background(theme.color(\.surfaceFill),
                        in: RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private func sectionView(_ section: BrushParameter.Section) -> some View {
        let parameters = BrushParameter.parameters(in: section).filter { $0.isShown(draft) }
        VStack(alignment: .leading, spacing: InkSpacing.m) {
            sectionTitle(section.rawValue)
            discreteControls(for: section)
            ForEach(parameters) { parameter in
                InkSliderRow(verbatim: parameter.label,
                             value: Binding(get: { parameter.get(draft) },
                                            set: { draft = parameter.setting($0, on: draft) }),
                             in: parameter.range, valueText: parameter.text(for: draft))
            }
        }
    }

    /// The parameters that aren't numbers: tip shape, tilt on or off, texture kind and blend mode.
    @ViewBuilder
    private func discreteControls(for section: BrushParameter.Section) -> some View {
        switch section {
        case .nib:
            Picker("Tip", selection: Binding(get: { draft.tip.isRound }, set: { round in
                draft.tip = round ? .round : .ellipse(aspect: 0.35, angle: -0.6)
            })) {
                Text("Round").tag(true)
                Text("Flat (chisel)").tag(false)
            }
            .pickerStyle(.segmented)
        case .tilt:
            Toggle("Tilt shading", isOn: $draft.tilt.enabled)
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .tint(theme.color(\.accent))
        case .texture:
            Picker("Texture", selection: Binding(get: { draft.texture.kind }, set: { kind in
                draft.texture = switch kind {
                case .none: .none
                case .grain: .grain(scale: 1, contrast: 1, seed: 42)
                case .bristle: .bristle(count: 8, spread: 1)
                }
            })) {
                Text("None").tag(BrushDescriptor.Texture.Kind.none)
                Text("Grain").tag(BrushDescriptor.Texture.Kind.grain)
                Text("Bristle").tag(BrushDescriptor.Texture.Kind.bristle)
            }
            .pickerStyle(.segmented)
        case .look:
            Picker("Blend", selection: Binding(get: { draft.blend == .multiply }, set: {
                draft.blend = $0 ? .multiply : .normal
            })) {
                Text("Normal").tag(false)
                Text("Multiply (highlighter)").tag(true)
            }
            .pickerStyle(.segmented)
        case .pressure, .speed, .ends, .stroke, .jitter:
            EmptyView()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(theme.headlineFont)
            .foregroundStyle(theme.color(\.textPrimary))
    }

    private func save() {
        controller.select(tool)
        if draft != original {
            controller.saveEditedBrush(draft, for: tool)
        }
        if savesAsPen {
            controller.saveCurrentPen()
        }
        dismiss()
    }
}
