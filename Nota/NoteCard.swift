import NotaUI
import SwiftUI

/// Figma **Note Card**: a paper thumbnail on the desk, then title and detail.
struct NoteCard: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: NotaSpacing.sm) {
            let shape = RoundedRectangle(cornerRadius: NotaRadius.paper, style: .continuous)
            PaperThumbnail(paper: note.paper, tint: note.tint.color, seed: note.title)
                .aspectRatio(PaperThumbnail.aspectRatio, contentMode: .fit)
                .clipShape(shape)
                .overlay(alignment: .bottomTrailing) { badges }
                .notaElevation(.paper)
                .contentShape(.contextMenuPreview, shape)

            VStack(alignment: .leading, spacing: NotaSpacing.xxxs) {
                Text(note.title)
                    .font(NotaFont.subheadlineEmph)
                    .foregroundStyle(NotaColor.textPrimary)
                    .lineLimit(1)
                Text(note.subtitle)
                    .font(NotaFont.footnote)
                    .foregroundStyle(NotaColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(note.isFavorite ? "Favorite" : "")
    }

    @ViewBuilder
    private var badges: some View {
        if note.kind == .pdf || note.isShared || note.isFavorite {
            NotaTag {
                HStack(spacing: NotaSpacing.xxs) {
                    if note.kind == .pdf {
                        Text("PDF")
                    }
                    if note.isShared {
                        NotaIconView(.share, size: 12)
                    }
                    if note.isFavorite {
                        NotaIconView(.star, size: 12)
                    }
                }
            }
            .padding(NotaSpacing.s)
            .accessibilityHidden(true)
        }
    }
}

/// Figma **Paper** in miniature: warm paper with its ruling, a heading in the note's ink and placeholder
/// "handwriting" in black ink. Bar lengths derive from `seed`, so each note keeps the same thumbnail
/// between launches.
struct PaperThumbnail: View {
    let paper: PaperStyle
    let tint: Color
    let seed: String

    /// US Letter, as in Figma (190 × 246).
    static let aspectRatio: CGFloat = 190.0 / 246.0

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 190 // design reference width
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(NotaColor.paperSurface))

            let rule = NotaColor.paperRule
            switch paper {
            case .plain:
                break
            case .lined:
                // Figma Paper / Ruled: first rule at 14% of the height, then one every 10 pt.
                var y = 36 * unit
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: max(0.5, 0.75 * unit))),
                                 with: .color(rule))
                    y += 10 * unit
                }
            case .dotted:
                let step = 12 * unit
                let r = max(0.6, 1 * unit)
                var y = step
                while y < size.height {
                    var x = step
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                     with: .color(rule))
                        x += step
                    }
                    y += step
                }
            case .grid:
                let step = 12 * unit
                var path = Path()
                var v = step
                while v < size.width {
                    path.addRect(CGRect(x: v, y: 0, width: 0.5, height: size.height)); v += step
                }
                var h = step
                while h < size.height {
                    path.addRect(CGRect(x: 0, y: h, width: size.width, height: 0.5)); h += step
                }
                context.fill(path, with: .color(rule))
            }

            // Placeholder handwriting
            let widths = barWidths
            let inset = 18 * unit
            let usable = size.width - 2 * inset
            let heading = CGRect(x: inset, y: 20 * unit, width: usable * widths[0], height: 8 * unit)
            context.fill(Path(roundedRect: heading, cornerRadius: 4 * unit), with: .color(tint))
            for (i, fraction) in widths.dropFirst().enumerated() {
                let bar = CGRect(x: inset, y: (60 + CGFloat(i) * 20) * unit, width: usable * fraction, height: 6 * unit)
                context.fill(Path(roundedRect: bar, cornerRadius: 3 * unit), with: .color(NotaInk.black.color.opacity(0.75)))
            }
        }
        .accessibilityHidden(true)
    }

    private var barWidths: [CGFloat] {
        // Stable across launches, unlike `hashValue`.
        let hash = seed.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return [0.45 + CGFloat(hash % 23) / 100,
                0.70 + CGFloat((hash / 23) % 25) / 100,
                0.40 + CGFloat((hash / 575) % 30) / 100]
    }
}

#Preview {
    HStack(spacing: 24) {
        ForEach(PaperStyle.allCases) { paper in
            PaperThumbnail(paper: paper, tint: NoteTint.teal.color, seed: paper.rawValue)
                .aspectRatio(PaperThumbnail.aspectRatio, contentMode: .fit)
                .frame(width: 190)
        }
    }
    .padding()
}
