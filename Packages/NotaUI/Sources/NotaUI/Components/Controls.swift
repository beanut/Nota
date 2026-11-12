import SwiftUI

// MARK: - Icon button

/// Figma **Icon Button**: 40 × 36, 20 pt glyph. Selected lifts a raised tile and tints the glyph ink;
/// disabled greys the glyph.
public struct NotaIconButtonStyle: ButtonStyle {
    let isSelected: Bool

    public init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotaRadius.control, style: .continuous)
        configuration.label
            .font(.system(size: 17, weight: .medium)) // SF Symbol fallback matches the 20 pt line icons
            .foregroundStyle(!isEnabled ? NotaColor.textTertiary : isSelected ? NotaColor.textInk : NotaColor.textPrimary)
            .frame(width: NotaSize.iconButton.width, height: NotaSize.iconButton.height)
            .background {
                if isSelected {
                    shape.fill(NotaColor.bgRaised).notaElevation(.tile)
                } else if configuration.isPressed {
                    shape.fill(NotaColor.textPrimary.opacity(0.06))
                }
            }
            .contentShape(shape)
            .animation(.snappy(duration: 0.18), value: isSelected)
    }
}

public extension ButtonStyle where Self == NotaIconButtonStyle {
    static var notaIcon: NotaIconButtonStyle {
        NotaIconButtonStyle()
    }

    static func notaIcon(selected: Bool) -> NotaIconButtonStyle {
        NotaIconButtonStyle(isSelected: selected)
    }
}

// MARK: - Ink swatch

/// Figma **Ink Swatch**: a 28 pt target with a 20 pt dot. Selected shrinks the dot and adds a ring, so the
/// selection never relies on colour alone.
public struct InkSwatch: View {
    let ink: NotaInk
    let isSelected: Bool
    let action: () -> Void

    public init(_ ink: NotaInk, isSelected: Bool, action: @escaping () -> Void) {
        self.ink = ink
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(ink.color)
                    .overlay(Circle().strokeBorder(NotaColor.inkOutline, lineWidth: 1))
                    .frame(width: isSelected ? 16 : 20, height: isSelected ? 16 : 20)
                if isSelected {
                    Circle().strokeBorder(NotaColor.textPrimary, lineWidth: 2)
                }
            }
            .frame(width: NotaSize.swatch, height: NotaSize.swatch)
            .contentShape(Circle())
            .animation(.snappy(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ink.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Divider

/// The 1 × 20 pt rule between groups in a bar. Vertical in a horizontal bar and the other way round.
public struct NotaBarDivider: View {
    let axis: Axis

    /// - Parameter axis: the axis of the bar the divider sits in.
    public init(in axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(NotaColor.textTertiary)
            .frame(width: axis == .horizontal ? 1 : 20, height: axis == .horizontal ? 20 : 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Chips

/// Figma **Chip**. Filter / Filter Selected for filters (ink tint = selected everywhere); Suggestion for
/// AI prompt starters (violet tint).
public struct NotaChipStyle: ButtonStyle {
    public enum Kind: Sendable { case filter, suggestion }

    let kind: Kind
    let isSelected: Bool

    public init(_ kind: Kind = .filter, isSelected: Bool = false) {
        self.kind = kind
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        let emphasised = isSelected || kind == .suggestion
        configuration.label
            .font(emphasised ? NotaFont.subheadlineEmph : NotaFont.subheadline)
            .foregroundStyle(kind == .suggestion ? NotaColor.textAI : isSelected ? NotaColor.textInk : NotaColor.textPrimary)
            .padding(.horizontal, NotaSpacing.m)
            .frame(minHeight: 32)
            .background(kind == .suggestion ? NotaColor.bgAITint : isSelected ? NotaColor.bgInkTint : NotaColor.bgFill,
                        in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

public extension ButtonStyle where Self == NotaChipStyle {
    static func notaChip(selected: Bool) -> NotaChipStyle {
        NotaChipStyle(.filter, isSelected: selected)
    }
}

/// Figma **Chip / Tag**: a 24 pt label for citations, context and badges.
public struct NotaTag<Label: View>: View {
    let label: Label

    public init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    public var body: some View {
        label
            .font(NotaFont.captionEmph)
            .foregroundStyle(NotaColor.textSecondary)
            .padding(.horizontal, NotaSpacing.s)
            .frame(minHeight: 24)
            .background(NotaColor.bgFill, in: Capsule())
    }
}

// MARK: - Buttons

/// Figma **Button**. Primary = your action (indigo). AI = Nota acts for you (violet). Secondary = neutral.
/// Plain = text-only in bars. Large is a 44 pt touch target; Compact is 36 pt for toolbars.
public struct NotaButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, ai, secondary, plain }
    public enum Size: Sendable { case large, compact }

    let kind: Kind
    let size: Size

    public init(_ kind: Kind = .primary, size: Size = .large) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        NotaButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct NotaButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: NotaButtonStyle.Kind
    let size: NotaButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(size == .large ? NotaFont.calloutEmph : NotaFont.subheadlineEmph)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .large ? NotaSpacing.xl : NotaSpacing.l)
            .frame(minHeight: size == .large ? 44 : 36)
            .background(background, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .ai: NotaColor.textOnAccent
        case .secondary: NotaColor.textPrimary
        case .plain: NotaColor.textInk
        }
    }

    private var background: Color {
        switch kind {
        case .primary: NotaColor.accentInk
        case .ai: NotaColor.accentAI
        case .secondary: NotaColor.bgFill
        case .plain: .clear
        }
    }
}

public extension ButtonStyle where Self == NotaButtonStyle {
    static func nota(_ kind: NotaButtonStyle.Kind, size: NotaButtonStyle.Size = .large) -> NotaButtonStyle {
        NotaButtonStyle(kind, size: size)
    }
}

/// A Nota button label: an icon (18 pt large, 16 pt compact) before the title.
public struct NotaButtonLabel: View {
    let title: LocalizedStringKey
    let icon: NotaIcon?
    let size: NotaButtonStyle.Size

    public init(_ title: LocalizedStringKey, icon: NotaIcon? = nil, size: NotaButtonStyle.Size = .large) {
        self.title = title
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        HStack(spacing: NotaSpacing.xs) {
            if let icon {
                NotaIconView(icon, size: size == .large ? 18 : 16)
            }
            Text(title)
        }
    }
}

// MARK: - Slider row

/// Figma **Slider Row**: label and value above a system slider with an ink fill. Tuning is manual, so it
/// uses ink, not AI violet.
public struct NotaSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let label: LocalizedStringKey
    let valueText: String
    @Binding var value: Value
    let range: ClosedRange<Value>

    public init(_ label: LocalizedStringKey, value: Binding<Value>, in range: ClosedRange<Value>, valueText: String) {
        self.label = label
        _value = value
        self.range = range
        self.valueText = valueText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NotaSpacing.sm) {
            HStack {
                Text(label).foregroundStyle(NotaColor.textPrimary)
                Spacer()
                Text(valueText).foregroundStyle(NotaColor.textSecondary).monospacedDigit()
            }
            .font(NotaFont.subheadline)
            Slider(value: $value, in: range) { Text(label) }
                .tint(NotaColor.accentInk)
        }
    }
}

// MARK: - Surfaces

public extension View {
    /// The surface of a bar floating over the canvas (Figma Floating Pen Case, Page Bar): a capsule-ish
    /// rounded rectangle with a hairline border and the floating shadow.
    func notaFloatingBar(fill: Color = NotaColor.bgFill, cornerRadius: CGFloat = NotaRadius.bar) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(fill, in: shape)
            .overlay(shape.strokeBorder(NotaColor.borderCard, lineWidth: 0.5))
            .notaElevation(.floating)
    }

    /// Popover content styling (Figma Tool Options): raised background, Nota padding.
    func notaPopoverContent() -> some View {
        padding(.top, NotaSpacing.s)
            .padding(.bottom, NotaSpacing.m)
            .background(NotaColor.bgRaised)
            .presentationBackground(NotaColor.bgRaised)
            .presentationCompactAdaptation(.popover)
    }
}
