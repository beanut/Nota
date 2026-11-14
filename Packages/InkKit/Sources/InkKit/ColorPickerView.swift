import SwiftUI

/// The full colour picker: a saturation and brightness square over a hue bar, a hex field, the eyedropper,
/// recent colours and the user's palettes. Every change applies to the tool straight away; the final colour
/// goes into the recent colours when the picker closes.
///
/// Opened from the Pen Case: from the colour well after the quick colours (`quickColorIndex` nil), or by
/// tapping the selected quick colour again, which then also replaces that quick colour.
struct ColorPickerView: View {
    @ObservedObject var controller: CanvasController
    let tool: Tool
    let quickColorIndex: Int?
    /// Called to close the popover, e.g. before the eyedropper takes over the canvas.
    let dismiss: () -> Void

    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var hexText = ""
    @State private var original: PenColor?
    @State private var renamingPalette: ColorPalette?
    @State private var paletteName = ""
    @FocusState private var hexFocused: Bool
    @Environment(\.inkTheme) private var theme

    private var color: PenColor {
        controller.color(for: tool)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InkSpacing.m) {
                header
                SpectrumView(hue: hue, saturation: $saturation, brightness: $brightness) { commitHSB() }
                HueBar(hue: $hue) { commitHSB() }
                hexRow
                recents
                palettes
                if quickColorIndex != nil, controller.hasCustomQuickColors(for: tool) {
                    Button("Reset Quick Colors") {
                        controller.resetQuickColors(for: tool)
                        if let first = controller.quickColors(for: tool).first {
                            controller.setColor(first, for: tool)
                        }
                        syncFromColor()
                    }
                    .buttonStyle(InkSecondaryButtonStyle())
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, InkSpacing.l)
        }
        .frame(width: InkMetrics.spectrum.width + 2 * InkSpacing.l)
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .inkPopoverContent()
        .onAppear {
            original = color
            syncFromColor()
        }
        .onDisappear {
            if let original, color != original {
                controller.penTray.update { $0.addRecentColor(color) }
            }
        }
        .alert("Rename Palette", isPresented: Binding(get: { renamingPalette != nil },
                                                      set: {
                                                          if !$0 {
                                                              renamingPalette = nil
                                                          }
                                                      })) {
            TextField("Name", text: $paletteName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renamingPalette?.id {
                    controller.penTray.update { $0.renamePalette(id: id, to: paletteName) }
                }
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: InkSpacing.s) {
            Text(quickColorIndex == nil ? "Color" : "Quick Color")
                .font(theme.headlineFont)
                .foregroundStyle(theme.color(\.textPrimary))
            Spacer()
            Circle()
                .fill(color.color)
                .overlay(Circle().strokeBorder(theme.color(\.swatchOutline), lineWidth: 1))
                .frame(width: InkMetrics.swatch, height: InkMetrics.swatch)
                .accessibilityLabel("Current color \(color.hex)")
        }
        .padding(.top, InkSpacing.s)
    }

    private var hexRow: some View {
        HStack(spacing: InkSpacing.s) {
            Text("Hex")
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textSecondary))
            TextField("#RRGGBB", text: $hexText)
                .font(theme.bodyFont.monospaced())
                .foregroundStyle(theme.color(\.textPrimary))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($hexFocused)
                .submitLabel(.done)
                .onSubmit(commitHex)
                .onChange(of: hexFocused) { _, focused in
                    if !focused {
                        commitHex()
                    }
                }
                .padding(.horizontal, InkSpacing.s)
                .frame(height: InkMetrics.iconButton.height)
                .background(theme.color(\.surfaceFill),
                            in: RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous))
                .accessibilityLabel("Hex color")
            Button {
                controller.startEyedropper(for: tool, quickColorIndex: quickColorIndex)
                dismiss()
            } label: {
                InkIconView(.eyedropper)
            }
            .buttonStyle(.inkIcon)
            .accessibilityLabel("Eyedropper")
            .accessibilityHint("Pick a color from the page.")
        }
    }

    @ViewBuilder
    private var recents: some View {
        let recent = controller.penTray.tray.recentColors
        if !recent.isEmpty {
            section("Recent") {
                SwatchGrid(colors: recent, selected: color, name: { controller.colorName($0, for: tool) },
                           pick: pick)
            }
        }
    }

    private var palettes: some View {
        VStack(alignment: .leading, spacing: InkSpacing.m) {
            ForEach(controller.penTray.tray.palettes) { palette in
                VStack(alignment: .leading, spacing: InkSpacing.xs) {
                    HStack {
                        sectionTitle(palette.name)
                        Spacer()
                        Menu {
                            Button {
                                controller.penTray.update { $0.addColor(color, toPalette: palette.id) }
                            } label: {
                                Label("Add Current Color", systemImage: "plus")
                            }
                            .disabled(palette.colors.contains(color))
                            Button {
                                paletteName = palette.name
                                renamingPalette = palette
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                controller.penTray.update { $0.removePalette(id: palette.id) }
                            } label: {
                                Label("Delete Palette", systemImage: "trash")
                            }
                        } label: {
                            InkIconView(.more, size: 16)
                                .foregroundStyle(theme.color(\.textSecondary))
                                .frame(width: InkMetrics.swatch, height: InkMetrics.swatch)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(palette.name) options")
                    }
                    SwatchGrid(colors: palette.colors, selected: color, name: { controller.colorName($0, for: tool) },
                               pick: pick,
                               remove: { c in controller.penTray.update { $0.removeColor(c, fromPalette: palette.id) } },
                               add: palette.colors.contains(color) || palette.colors.count >= PenTray.maxPaletteColors
                                   ? nil : { controller.penTray.update { $0.addColor(color, toPalette: palette.id) } })
                }
            }
            Button {
                commitHexIfEditing()
                let current = color
                controller.penTray.update { $0.addPalette(named: "", colors: [current]) }
            } label: {
                HStack(spacing: InkSpacing.xs) {
                    InkIconView(.addPage, size: 16)
                    Text("New Palette")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkSecondaryButtonStyle())
            .accessibilityHint("Starts a palette with the current color.")
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InkSpacing.xs) {
            sectionTitle(title)
            content()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(theme.footnoteEmphasizedFont)
            .foregroundStyle(theme.color(\.textSecondary))
            .lineLimit(1)
    }

    // MARK: Changes

    private func pick(_ picked: PenColor) {
        apply(picked)
        syncFromColor()
    }

    private func apply(_ new: PenColor) {
        if let index = quickColorIndex {
            controller.setQuickColor(new, at: index, for: tool)
        }
        controller.setColor(new, for: tool)
    }

    private func commitHSB() {
        apply(PenColor(hue: hue, saturation: saturation, brightness: brightness))
        hexText = color.hex
    }

    /// Applies a hex code still being typed, so a button tapped straight after uses it.
    private func commitHexIfEditing() {
        if hexFocused {
            commitHex()
        }
    }

    private func commitHex() {
        if let parsed = PenColor(hex: hexText) {
            pick(parsed)
        } else {
            hexText = color.hex
        }
    }

    /// Takes hue, saturation and brightness from the current colour, keeping the hue for greys.
    private func syncFromColor() {
        let hsb = color.hsb
        if hsb.saturation > 0, hsb.brightness > 0 {
            hue = hsb.hue
        }
        if hsb.brightness > 0 {
            saturation = hsb.saturation
        }
        brightness = hsb.brightness
        hexText = color.hex
    }
}

// MARK: - Spectrum

/// Saturation (left to right) and brightness (bottom to top) at one hue.
private struct SpectrumView: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    let onChange: () -> Void
    @Environment(\.inkTheme) private var theme

    var body: some View {
        let size = InkMetrics.spectrum
        let shape = RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous)
        // The spectrum shows ink colours, not chrome, so it's drawn from the colour itself.
        ZStack {
            PenColor(hue: hue, saturation: 1, brightness: 1).color
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.color(\.swatchOutline), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Knob(color: PenColor(hue: hue, saturation: saturation, brightness: brightness))
                .position(x: saturation * size.width, y: (1 - brightness) * size.height)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            saturation = min(max(value.location.x / size.width, 0), 1)
            brightness = 1 - min(max(value.location.y / size.height, 0), 1)
            onChange()
        })
        .accessibilityElement()
        .accessibilityLabel("Saturation and brightness")
        .accessibilityValue("Saturation \(Int(saturation * 100))%, brightness \(Int(brightness * 100))%")
        .accessibilityAdjustableAction { direction in
            brightness = min(max(brightness + (direction == .increment ? 0.05 : -0.05), 0), 1)
            onChange()
        }
    }
}

/// The hue, left to right.
private struct HueBar: View {
    @Binding var hue: Double
    let onChange: () -> Void
    @Environment(\.inkTheme) private var theme

    var body: some View {
        let width = InkMetrics.spectrum.width
        let height = InkMetrics.hueBarHeight
        let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { PenColor(hue: $0, saturation: 1, brightness: 1).color }
        Capsule()
            .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
            .overlay(Capsule().strokeBorder(theme.color(\.swatchOutline), lineWidth: 1))
            .overlay(alignment: .leading) {
                Knob(color: PenColor(hue: hue, saturation: 1, brightness: 1))
                    .offset(x: hue * (width - InkMetrics.knob))
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                hue = min(max((value.location.x - InkMetrics.knob / 2) / (width - InkMetrics.knob), 0), 0.9999)
                onChange()
            })
            .accessibilityElement()
            .accessibilityLabel("Hue")
            .accessibilityValue("\(Int(hue * 360)) degrees")
            .accessibilityAdjustableAction { direction in
                hue = (hue + (direction == .increment ? 1.0 / 36 : -1.0 / 36) + 1).truncatingRemainder(dividingBy: 1)
                onChange()
            }
    }
}

/// A draggable ring showing the colour under it.
private struct Knob: View {
    let color: PenColor
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Circle()
            .fill(color.color)
            .overlay(Circle().strokeBorder(theme.color(\.surfaceRaised), lineWidth: 3))
            .overlay(Circle().strokeBorder(theme.color(\.swatchOutline), lineWidth: 1))
            .frame(width: InkMetrics.knob, height: InkMetrics.knob)
            .shadow(color: theme.color(\.shadow).opacity(0.2), radius: 2, y: 1)
            .allowsHitTesting(false)
    }
}

// MARK: - Swatch grid

/// Colour swatches that wrap, with an optional add button; a long press offers Remove when `remove` is set.
struct SwatchGrid: View {
    let colors: [PenColor]
    let selected: PenColor
    let name: (PenColor) -> String
    let pick: (PenColor) -> Void
    var remove: ((PenColor) -> Void)?
    var add: (() -> Void)?
    @Environment(\.inkTheme) private var theme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(InkMetrics.swatch), spacing: InkSpacing.xxs), count: 9),
                  alignment: .leading, spacing: InkSpacing.xxs) {
            ForEach(colors, id: \.self) { color in
                InkSwatchButton(color: color, name: name(color), isSelected: color == selected) { pick(color) }
                    .contextMenu {
                        if let remove {
                            Button(role: .destructive) { remove(color) } label: {
                                Label("Remove from Palette", systemImage: "minus.circle")
                            }
                        }
                    }
            }
            if let add {
                Button(action: add) {
                    InkIconView(.addPage, size: 14)
                        .foregroundStyle(theme.color(\.textSecondary))
                        .frame(width: InkMetrics.swatch, height: InkMetrics.swatch)
                        .overlay(Circle().strokeBorder(theme.color(\.textTertiary),
                                                       style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add current color")
            }
        }
    }
}

// MARK: - Colour well

/// The button after the quick colours that opens the full picker: a hue ring around the current colour
/// when it isn't one of the quick colours, so a picked colour still shows as selected.
struct ColorWellButton: View {
    let color: PenColor
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Button(action: action) {
            let ring = AngularGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6)
                .map { PenColor(hue: $0, saturation: 0.85, brightness: 0.95).color }, center: .center)
            ZStack {
                Circle().strokeBorder(ring, lineWidth: 3)
                    .frame(width: 22, height: 22)
                Circle()
                    .fill(isSelected ? color.color : theme.color(\.surfaceRaised))
                    .overlay(Circle().strokeBorder(theme.color(\.swatchOutline), lineWidth: 1))
                    .frame(width: 12, height: 12)
            }
            .frame(width: InkMetrics.swatch, height: InkMetrics.swatch)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More colors")
        .accessibilityValue(isSelected ? color.hex : "")
        .accessibilityHint("Opens the color picker.")
    }
}
