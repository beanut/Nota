import SwiftUI

/// The tape tool's options: what new tape is printed with, and revealing or hiding all of the page's tape.
/// Its colour is the Pen Case's (the theme's tape colours) and its width the width controls'.
struct TapeOptions: View {
    @ObservedObject var controller: CanvasController
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.s) {
            Picker("Pattern", selection: $controller.tapePattern) {
                Text("Plain").tag(TapeObject.Pattern.plain)
                Text("Striped").tag(TapeObject.Pattern.striped)
                Text("Grid").tag(TapeObject.Pattern.grid)
            }
            .pickerStyle(.segmented)
            HStack(spacing: InkSpacing.xs) {
                Button { controller.setAllTape(revealed: true) } label: {
                    Text("Reveal All").lineLimit(1).frame(maxWidth: .infinity)
                }
                Button { controller.setAllTape(revealed: false) } label: {
                    Text("Hide All").lineLimit(1).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(InkSecondaryButtonStyle())
            Text("Drag to cover part of the page with tape. Tap tape with any tool to reveal or hide what's under it.")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The laser pointer's options: a fading trail, or a dot that follows the touch.
struct LaserOptions: View {
    @ObservedObject var controller: CanvasController
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.s) {
            Picker("Laser", selection: $controller.laserMode) {
                Text("Trail").tag(LaserTrail.Mode.trail)
                Text("Dot").tag(LaserTrail.Mode.dot)
            }
            .pickerStyle(.segmented)
            Text("Point at the page while you present. Nothing is written on it, and the trail fades after a moment.")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown over the editor while an external display mirrors the page, so it's clear what the audience sees.
struct PresentingBadge: View {
    @ObservedObject var presentation: InkPresentation
    @Environment(\.inkTheme) private var theme

    var body: some View {
        if presentation.isMirroring {
            HStack(spacing: InkSpacing.xs) {
                InkIconView(.laser, size: 14)
                Text("Presenting this page")
                    .font(theme.footnoteEmphasizedFont)
            }
            .foregroundStyle(theme.color(\.textSecondary))
            .padding(.horizontal, InkSpacing.m)
            .frame(height: InkMetrics.swatch)
            .inkFloatingBar(fill: \.surfaceRaised)
            .accessibilityElement(children: .combine)
        }
    }
}
