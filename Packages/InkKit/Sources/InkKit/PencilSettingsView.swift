import SwiftUI

extension PencilSettings.Action {
    var title: LocalizedStringKey {
        switch self {
        case .system: "System Setting"
        case .eraser: "Switch to Eraser"
        case .previousTool: "Previous Tool"
        case .palette: "Show Palette"
        case .off: "Off"
        }
    }
}

extension PencilSettings.FingerDrawing {
    var title: LocalizedStringKey {
        switch self {
        case .system: "System Setting"
        case .pencilOnly: "Pencil Only"
        case .fingerDraws: "Finger Draws"
        }
    }
}

extension PencilSettings.PalmRejection {
    var title: LocalizedStringKey {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

extension PencilSettings.Handedness {
    var title: LocalizedStringKey {
        switch self {
        case .right: "Right"
        case .left: "Left"
        }
    }
}

/// The More menu's Apple Pencil settings: double-tap and squeeze, finger drawing, palm rejection,
/// handedness and scribble gestures.
struct PencilSettingsView: View {
    @ObservedObject var controller: CanvasController
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.l) {
            Text("Apple Pencil")
                .font(theme.headlineFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .padding(.top, InkSpacing.s)

            section("Gestures") {
                picker("Double-tap", selection: $controller.pencilSettings.doubleTap,
                       options: PencilSettings.Action.allCases, title: \.title)
                picker("Squeeze", selection: $controller.pencilSettings.squeeze,
                       options: PencilSettings.Action.allCases, title: \.title)
                footnote("System Setting follows Settings › Apple Pencil. Squeeze needs Apple Pencil Pro.")
            }

            section("Drawing") {
                picker("Finger", selection: $controller.pencilSettings.fingerDrawing,
                       options: PencilSettings.FingerDrawing.allCases, title: \.title)
                footnote("""
                With Finger Draws, one finger draws and two pan. System Setting follows Only Draw with Apple Pencil.
                """)
            }

            section("Palm Rejection") {
                Picker("Palm rejection", selection: $controller.pencilSettings.palmRejection) {
                    ForEach(PencilSettings.PalmRejection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    Text("Writing hand")
                    Spacer(minLength: InkSpacing.s)
                    Picker("Writing hand", selection: $controller.pencilSettings.handedness) {
                        ForEach(PencilSettings.Handedness.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                footnote("""
                Higher ignores more of a resting hand, but also more real fingers near the Pencil. \
                The writing hand sets where palms are expected and where the palette opens.
                """)
            }

            section("Scribble") {
                Toggle("Circle and hold to select", isOn: $controller.pencilSettings.circleToSelect)
                Toggle("Draw and hold to snap shapes", isOn: $controller.pencilSettings.holdToSnapShapes)
            }
        }
        .font(theme.bodyFont)
        .foregroundStyle(theme.color(\.textPrimary))
        .tint(theme.color(\.accent))
        .padding(.horizontal, InkSpacing.xl)
        .padding(.bottom, InkSpacing.s)
        .frame(width: 360)
        .inkPopoverContent()
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InkSpacing.xs) {
            Text(title)
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
            content()
        }
    }

    private func picker<Option: Hashable & Identifiable>(
        _ label: LocalizedStringKey, selection: Binding<Option>, options: [Option],
        title: KeyPath<Option, LocalizedStringKey>
    ) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: InkSpacing.s)
            Picker(label, selection: selection) {
                ForEach(options) { Text($0[keyPath: title]).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(theme.footnoteFont)
            .foregroundStyle(theme.color(\.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
