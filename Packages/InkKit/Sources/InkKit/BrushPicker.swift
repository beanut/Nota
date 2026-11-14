import SwiftUI

/// The brushes a tool can draw with, as tiles that each show a sample stroke drawn by the engine in the
/// tool's current ink. Part of the tool options popover.
struct BrushPicker: View {
    @ObservedObject var controller: CanvasController
    let tool: Tool
    @Environment(\.inkTheme) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let brushes = controller.availableBrushes(for: tool)
        let selected = controller.brush(for: tool).id
        let color = controller.color(for: tool).rgba
        LazyVGrid(columns: [GridItem(.flexible(), spacing: InkSpacing.s), GridItem(.flexible(), spacing: InkSpacing.s)],
                  spacing: InkSpacing.s) {
            ForEach(brushes) { brush in
                let isSelected = brush.id == selected
                Button { controller.selectBrush(brush, for: tool) } label: {
                    VStack(spacing: InkSpacing.xxs) {
                        preview(brush, color: color)
                            .frame(height: InkMetrics.brushPreview.height)
                        Text(brush.name)
                            .font(isSelected ? theme.footnoteEmphasizedFont : theme.footnoteFont)
                            .foregroundStyle(theme.color(isSelected ? \.textSelected : \.textSecondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.vertical, InkSpacing.xs)
                    .frame(maxWidth: .infinity)
                    .background(theme.color(isSelected ? \.surfaceSelected : \.surfaceFill),
                                in: RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(brush.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .contextMenu { menu(for: brush) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Brushes")
    }

    @ViewBuilder
    private func preview(_ brush: BrushDescriptor, color: RGBA) -> some View {
        if let image = BrushPreview.image(of: brush, color: color, scale: displayScale) {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func menu(for brush: BrushDescriptor) -> some View {
        let custom = controller.isCustomBrush(brush, for: tool)
        Button {
            controller.selectBrush(brush, for: tool)
            controller.editBrush(for: tool)
        } label: {
            Label(custom ? "Edit Brush…" : "Edit a Copy…", systemImage: "slider.horizontal.3")
        }
        if custom {
            Button(role: .destructive) { controller.deleteCustomBrush(brush, for: tool) } label: {
                Label("Delete Brush", systemImage: "trash")
            }
        }
    }
}

/// A brush's sample stroke: a short handwriting-like wave with pressure building and easing off, drawn
/// by the renderer itself, so the picker shows exactly what the brush draws. Cached per brush and ink.
@MainActor
enum BrushPreview {
    private static var cache: [Key: CGImage] = [:]

    private struct Key: Hashable {
        let brush: BrushDescriptor
        let color: RGBA
        let scale: CGFloat
        let size: CGSize
        let fits: Bool
    }

    /// The sample stroke at `size` points. `fits` scales the brush's width to suit the preview (the
    /// picker); otherwise it's drawn at its own width, on a page as tall as the preview (the brush editor).
    static func image(of brush: BrushDescriptor, color: RGBA, scale: CGFloat,
                      size: CGSize = InkMetrics.brushPreview, fits: Bool = true) -> CGImage? {
        let key = Key(brush: brush, color: color, scale: scale, size: size, fits: fits)
        if let image = cache[key] {
            return image
        }
        // Fitted previews are drawn on a page twice their size (pages have a minimum size), then scaled down.
        let factor: CGFloat = fits ? 2 : 1
        let page = CGSize(width: size.width * factor, height: size.height * factor)
        let doc = CanvasDocument(pageSize: PageSize(width: page.width, height: page.height))
        let drawn = fits ? previewBrush(brush, pageHeight: page.height)
            : brush.sized(min(brush.maxWidth, page.height * 0.6),
                          minimumRatio: brush.maxWidth > 0 ? brush.size.lowerBound / brush.maxWidth : 1)
        doc.add(Stroke(id: UUID(), color: color, brush: drawn, points: samplePoints(in: page)))
        let image = PageRenderer.image(of: doc.snapshot(), pixelWidth: Int((size.width * scale).rounded()))
        if cache.count > 64 {
            cache.removeAll()
        }
        cache[key] = image
        return image
    }

    /// The brush at a width that fits the preview, keeping its character.
    private static func previewBrush(_ brush: BrushDescriptor, pageHeight: CGFloat) -> BrushDescriptor {
        let width = min(brush.maxWidth * 1.6, pageHeight * 0.42)
        return brush.sized(width, minimumRatio: brush.maxWidth > 0 ? brush.size.lowerBound / brush.maxWidth : 1)
    }

    private static func samplePoints(in size: CGSize) -> [StrokePoint] {
        let count = 60
        return (0 ..< count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            let x = size.width * (0.08 + 0.84 * t)
            let y = size.height * (0.5 + 0.28 * sin(t * 2 * .pi * 1.25))
            return StrokePoint(location: CGPoint(x: x, y: y), force: 0.2 + 0.75 * sin(t * .pi),
                               altitude: 75 * .pi / 180, azimuth: -.pi / 4, timestamp: Double(i) / 60)
        }
    }
}
