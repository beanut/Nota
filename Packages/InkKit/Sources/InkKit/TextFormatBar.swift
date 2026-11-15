import SwiftUI

/// The floating bar over the page while a text box is edited: typeface, size, bold / italic / underline,
/// alignment, lists (bullets, numbers, checkboxes), indent and Done. Colour comes from the Pen Case's
/// colours, which recolour the selected text while the bar is up. The format glyphs are SF Symbols.
struct TextFormatBar: View {
    @ObservedObject var controller: CanvasController
    let state: TextFormatState
    @Environment(\.inkTheme) private var theme

    var body: some View {
        HStack(spacing: InkSpacing.xxxs) {
            fontMenu
            sizeControls
            InkBarDivider(axis: .horizontal)
            toggle("bold", "Bold", state.style.bold) { .bold($0) }
            toggle("italic", "Italic", state.style.italic) { .italic($0) }
            toggle("underline", "Underline", state.style.underline) { .underline($0) }
            InkBarDivider(axis: .horizontal)
            alignmentMenu
            list(.bullet, "list.bullet", "Bulleted List")
            list(.numbered, "list.number", "Numbered List")
            list(.checkbox, "checklist", "Checklist")
            Button { controller.formatText(.indent(-1)) } label: { symbol("decrease.indent") }
                .buttonStyle(.inkIcon)
                .disabled(state.indent == 0)
                .accessibilityLabel("Decrease Indent")
            Button { controller.formatText(.indent(1)) } label: { symbol("increase.indent") }
                .buttonStyle(.inkIcon)
                .disabled(state.indent >= TextParagraph.maxIndent)
                .accessibilityLabel("Increase Indent")
            InkBarDivider(axis: .horizontal)
            Button("Done") { controller.endTextEditing() }
                .font(theme.bodyEmphasizedFont)
                .foregroundStyle(theme.color(\.textSelected))
                .padding(.horizontal, InkSpacing.s)
                .frame(height: InkMetrics.iconButton.height)
                .accessibilityHint("Finishes editing the text box.")
        }
        .padding(.horizontal, InkSpacing.xs)
        .frame(height: InkMetrics.barHeight)
        .inkFloatingBar()
    }

    private var fontMenu: some View {
        Menu {
            Picker("Font", selection: Binding(get: { state.style.font }, set: { controller.formatText(.font($0)) })) {
                ForEach(TextFont.allCases) { font in
                    Text(font.title).tag(font)
                }
            }
        } label: {
            Text(state.style.font.title)
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .lineLimit(1)
                .padding(.horizontal, InkSpacing.s)
                .frame(minWidth: 96, minHeight: InkMetrics.iconButton.height)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Font")
        .accessibilityValue(state.style.font.title)
    }

    private var sizeControls: some View {
        let size = state.style.size
        return HStack(spacing: 0) {
            Button { controller.formatText(.size(Self.step(size, up: false))) } label: { symbol("minus") }
                .buttonStyle(.inkIcon)
                .disabled(size <= TextStyle.sizeRange.lowerBound)
                .accessibilityLabel("Smaller")
            Menu {
                ForEach(TextStyle.presetSizes, id: \.self) { preset in
                    Button("\(Int(preset)) pt") { controller.formatText(.size(preset)) }
                }
            } label: {
                Text("\(Int(size.rounded()))")
                    .font(theme.bodyFont.monospacedDigit())
                    .foregroundStyle(theme.color(\.textPrimary))
                    .frame(minWidth: 28, minHeight: InkMetrics.iconButton.height)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Size")
            .accessibilityValue("\(Int(size.rounded())) points")
            Button { controller.formatText(.size(Self.step(size, up: true))) } label: { symbol("plus") }
                .buttonStyle(.inkIcon)
                .disabled(size >= TextStyle.sizeRange.upperBound)
                .accessibilityLabel("Larger")
        }
    }

    /// The next preset size above or below `size`.
    static func step(_ size: CGFloat, up: Bool) -> CGFloat {
        let presets = TextStyle.presetSizes
        if up {
            return presets.first { $0 > size + 0.01 } ?? min(size + 12, TextStyle.sizeRange.upperBound)
        }
        return presets.last { $0 < size - 0.01 } ?? max(size - 1, TextStyle.sizeRange.lowerBound)
    }

    private var alignmentMenu: some View {
        Menu {
            Picker("Alignment", selection: Binding(get: { state.alignment },
                                                   set: { controller.formatText(.alignment($0)) })) {
                ForEach(TextAlignment.allCases) { alignment in
                    Label(Self.title(of: alignment), systemImage: Self.symbol(of: alignment)).tag(alignment)
                }
            }
        } label: {
            symbol(Self.symbol(of: state.alignment))
                .frame(width: InkMetrics.iconButton.width, height: InkMetrics.iconButton.height)
                .foregroundStyle(theme.color(\.textPrimary))
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Alignment")
        .accessibilityValue(Self.title(of: state.alignment))
    }

    private func toggle(_ symbolName: String, _ label: LocalizedStringKey, _ isOn: Bool,
                        _ change: @escaping (Bool) -> TextFormatChange) -> some View {
        Button { controller.formatText(change(!isOn)) } label: { symbol(symbolName) }
            .buttonStyle(.inkIcon(selected: isOn))
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func list(_ list: TextList, _ symbolName: String, _ label: LocalizedStringKey) -> some View {
        let isOn = state.list == list
        return Button { controller.formatText(.list(isOn ? .none : list)) } label: { symbol(symbolName) }
            .buttonStyle(.inkIcon(selected: isOn))
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .frame(width: InkMetrics.iconSize, height: InkMetrics.iconSize)
    }

    private static func title(of alignment: TextAlignment) -> String {
        switch alignment {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .justified: "Justified"
        }
    }

    private static func symbol(of alignment: TextAlignment) -> String {
        switch alignment {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        }
    }
}

/// The text tool's options: the typeface and size new text boxes start in. Their colour is the Pen Case's.
struct TextToolOptions: View {
    @ObservedObject var controller: CanvasController
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.s) {
            Picker("Font", selection: $controller.newTextFont) {
                ForEach(TextFont.allCases) { font in
                    Text(font.title).tag(font)
                }
            }
            .pickerStyle(.menu)
            InkSliderRow("Size", value: Binding(get: { controller.newTextSize },
                                                set: { controller.newTextSize = $0.rounded() }),
                         in: 8 ... 72, valueText: "\(Int(controller.newTextSize.rounded())) pt")
            Text("Tap the page to type, or drag to set the box's width. Tap a text box to edit it.")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
