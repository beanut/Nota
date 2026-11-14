import SwiftUI

/// Covers the canvas while the eyedropper is on: touch or drag on the page to see the colour under the
/// finger or Pencil in a loupe above it, and lift to use it. Cancel leaves the colour as it was. Laid out
/// in the canvas view's coordinate space, so locations map straight onto `CanvasView.sampledColor(at:)`.
struct EyedropperOverlay: View {
    @ObservedObject var controller: CanvasController
    @State private var location: CGPoint?
    @State private var sampled: PenColor?
    @Environment(\.inkTheme) private var theme

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001) // catches every touch, so nothing draws
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        location = value.location
                        sampled = controller.sampleColor(at: value.location)
                    }
                    .onEnded { value in
                        let color = controller.sampleColor(at: value.location) ?? sampled
                        location = nil
                        controller.finishEyedropper(with: color)
                    })
                .accessibilityLabel("Page")
                .accessibilityHint("Touch the page to pick the color under your finger.")

            if let location, let sampled {
                loupe(sampled)
                    .position(x: location.x, y: max(location.y - InkMetrics.loupe, InkMetrics.loupe / 2))
                    .allowsHitTesting(false)
            }
        }
    }

    private func loupe(_ color: PenColor) -> some View {
        Circle()
            .fill(color.color)
            .overlay(Circle().strokeBorder(theme.color(\.surfaceRaised), lineWidth: 4))
            .overlay(Circle().strokeBorder(theme.color(\.border), lineWidth: 0.5))
            .frame(width: InkMetrics.loupe, height: InkMetrics.loupe)
            .shadow(color: theme.color(\.shadow).opacity(0.18), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}

/// The eyedropper's instructions and Cancel, floating at the top of the canvas inside the safe area (the
/// overlay itself covers the whole canvas, under the navigation bar).
struct EyedropperBanner: View {
    @ObservedObject var controller: CanvasController
    @Environment(\.inkTheme) private var theme

    var body: some View {
        HStack(spacing: InkSpacing.s) {
            InkIconView(.eyedropper, size: 16)
                .foregroundStyle(theme.color(\.textSecondary))
            Text("Touch the page to pick a color")
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textPrimary))
            Button("Cancel") { controller.finishEyedropper(with: nil) }
                .font(theme.bodyEmphasizedFont)
                .foregroundStyle(theme.color(\.textSelected))
        }
        .padding(.horizontal, InkSpacing.l)
        .frame(height: 44)
        .inkFloatingBar(fill: \.surfaceRaised)
        .padding(.top, InkSpacing.s)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
