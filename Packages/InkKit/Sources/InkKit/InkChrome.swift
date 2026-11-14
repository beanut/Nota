import SwiftUI

// The controls InkKit's chrome is built from. They take their colours, fonts and icons from the
// environment's `InkTheme`; spacing and sizes are fixed here.

/// Spacing scale, in points.
enum InkSpacing {
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let s: CGFloat = 8
    static let sm: CGFloat = 10
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

enum InkMetrics {
    /// Icon buttons and width presets.
    static let controlRadius: CGFloat = 10
    /// Floating bars: half their 44 pt height, so they read as capsules.
    static let barRadius: CGFloat = 22
    static let iconSize: CGFloat = 20
    static let iconButton = CGSize(width: 40, height: 36)
    static let swatch: CGFloat = 28
    /// A brush's sample stroke in the brush picker, in points.
    static let brushPreview = CGSize(width: 110, height: 26)
    /// A saved pen's sample stroke in the pen tray.
    static let penPreview = CGSize(width: 96, height: 24)
    /// The brush editor's live preview.
    static let brushEditorPreview = CGSize(width: 480, height: 96)
    /// The colour picker's saturation and brightness square, and its hue bar.
    static let spectrum = CGSize(width: 288, height: 176)
    static let hueBarHeight: CGFloat = 24
    /// The colour picker's knobs.
    static let knob: CGFloat = 24
    /// The eyedropper's loupe.
    static let loupe: CGFloat = 64
}

extension InkTheme {
    func color(_ keyPath: KeyPath<InkTheme, UIColor>) -> Color {
        Color(uiColor: self[keyPath: keyPath])
    }
}

// MARK: - Icon

/// A theme icon, template-rendered at `size`.
struct InkIconView: View {
    let icon: InkIcon
    var size: CGFloat = InkMetrics.iconSize
    @Environment(\.inkTheme) private var theme

    init(_ icon: InkIcon, size: CGFloat = InkMetrics.iconSize) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        theme.icon(icon)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Icon button

/// 40 × 36 with a 20 pt glyph. Selected lifts a raised tile and tints the glyph; disabled greys it.
struct InkIconButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.inkTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous)
        configuration.label
            .foregroundStyle(theme.color(!isEnabled ? \.textTertiary : isSelected ? \.textSelected : \.textPrimary))
            .frame(width: InkMetrics.iconButton.width, height: InkMetrics.iconButton.height)
            .background {
                if isSelected {
                    shape.fill(theme.color(\.surfaceRaised))
                        .shadow(color: .black.opacity(0.08), radius: 0.75, y: 1)
                } else if configuration.isPressed {
                    shape.fill(theme.color(\.textPrimary).opacity(0.06))
                }
            }
            .contentShape(shape)
            .animation(.snappy(duration: 0.18), value: isSelected)
    }
}

extension ButtonStyle where Self == InkIconButtonStyle {
    static var inkIcon: InkIconButtonStyle {
        InkIconButtonStyle()
    }

    static func inkIcon(selected: Bool) -> InkIconButtonStyle {
        InkIconButtonStyle(isSelected: selected)
    }
}

// MARK: - Secondary button

/// A neutral 36 pt capsule button, for actions inside popovers.
struct InkSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.inkTheme) private var theme

    var body: some View {
        configuration.label
            .font(theme.bodyEmphasizedFont)
            .foregroundStyle(theme.color(\.textPrimary))
            .padding(.horizontal, InkSpacing.l)
            .frame(minHeight: 36)
            .background(theme.color(\.surfaceFill), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

// MARK: - Ink swatch

/// A 28 pt target with a 20 pt dot. Selected shrinks the dot and adds a ring, so the selection never relies
/// on colour alone.
struct InkSwatchButton: View {
    let color: PenColor
    /// VoiceOver's name for the colour.
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.color)
                    .overlay(Circle().strokeBorder(theme.color(\.swatchOutline), lineWidth: 1))
                    .frame(width: isSelected ? 16 : 20, height: isSelected ? 16 : 20)
                if isSelected {
                    Circle().strokeBorder(theme.color(\.textPrimary), lineWidth: 2)
                }
            }
            .frame(width: InkMetrics.swatch, height: InkMetrics.swatch)
            .contentShape(Circle())
            .animation(.snappy(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Divider

/// The 1 × 20 pt rule between groups in a bar. Vertical in a horizontal bar and the other way round.
struct InkBarDivider: View {
    var axis: Axis = .horizontal
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.color(\.textTertiary))
            .frame(width: axis == .horizontal ? 1 : 20, height: axis == .horizontal ? 20 : 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Slider row

/// Label and value above a slider tinted with the theme's accent.
struct InkSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let label: LocalizedStringKey
    @Binding var value: Value
    let range: ClosedRange<Value>
    let valueText: String
    @Environment(\.inkTheme) private var theme

    init(_ label: LocalizedStringKey, value: Binding<Value>, in range: ClosedRange<Value>, valueText: String) {
        self.label = label
        _value = value
        self.range = range
        self.valueText = valueText
    }

    init(verbatim label: String, value: Binding<Value>, in range: ClosedRange<Value>, valueText: String) {
        self.init(LocalizedStringKey(label), value: value, in: range, valueText: valueText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.sm) {
            HStack {
                Text(label).foregroundStyle(theme.color(\.textPrimary))
                Spacer()
                Text(valueText).foregroundStyle(theme.color(\.textSecondary)).monospacedDigit()
            }
            .font(theme.bodyFont)
            Slider(value: $value, in: range) { Text(label) }
                .tint(theme.color(\.accent))
        }
    }
}

// MARK: - Surfaces

private struct FloatingBar: ViewModifier {
    let fill: KeyPath<InkTheme, UIColor>
    @Environment(\.inkTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: InkMetrics.barRadius, style: .continuous)
        let shadow = theme.color(\.shadow)
        content
            .background(theme.color(fill), in: shape)
            .overlay(shape.strokeBorder(theme.color(\.border), lineWidth: 0.5))
            .shadow(color: shadow.opacity(0.10), radius: 6, y: 8)
            .shadow(color: shadow.opacity(0.08), radius: 0.5, y: 1)
    }
}

private struct PopoverContent: ViewModifier {
    @Environment(\.inkTheme) private var theme

    func body(content: Content) -> some View {
        let background = theme.color(\.surfaceRaised)
        content
            .padding(.top, InkSpacing.s)
            .padding(.bottom, InkSpacing.m)
            .background(background)
            .presentationBackground(background)
            .presentationCompactAdaptation(.popover)
    }
}

extension View {
    /// A bar floating over the canvas: a capsule with a hairline border and a soft shadow.
    func inkFloatingBar(fill: KeyPath<InkTheme, UIColor> = \.surfaceFill) -> some View {
        modifier(FloatingBar(fill: fill))
    }

    /// Popover content: raised background and padding.
    func inkPopoverContent() -> some View {
        modifier(PopoverContent())
    }
}
