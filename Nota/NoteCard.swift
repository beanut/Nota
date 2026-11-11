import SwiftUI

/// A note in the library grid: a paper thumbnail with its cover colour, then title and page count.
struct NoteCard: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaperThumbnail(paper: note.paper, tint: note.tint.color, seed: note.title)
                .aspectRatio(0.97, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.black.opacity(0.06))
                }
                .overlay(alignment: .bottomTrailing) { badges }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(note.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(note.isFavorite ? "Favorite" : "")
    }

    @ViewBuilder
    private var badges: some View {
        let symbols = [
            note.kind == .pdf ? "doc.richtext" : nil,
            note.isShared ? "person.2.fill" : nil,
            note.isFavorite ? "star.fill" : nil,
        ].compactMap { $0 }
        if !symbols.isEmpty {
            HStack(spacing: 6) {
                ForEach(symbols, id: \.self) { Image(systemName: $0) }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(8)
            .accessibilityHidden(true)
        }
    }
}

/// Miniature page: coloured cover band, paper pattern, and placeholder "handwriting" bars in the cover
/// colour. Bar lengths derive from `seed`, so each note keeps the same thumbnail between launches.
struct PaperThumbnail: View {
    let paper: PaperStyle
    let tint: Color
    let seed: String

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 190   // design reference width
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

            let rule = Color(red: 0.86, green: 0.87, blue: 0.91)
            switch paper {
            case .plain:
                break
            case .lined:
                var y = 28 * unit
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: max(0.5, 0.75 * unit))),
                                 with: .color(rule))
                    y += 26 * unit
                }
            case .dotted:
                let step = 17 * unit
                let r = max(0.6, 1 * unit)
                var y = step
                while y < size.height {
                    var x = step
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                     with: .color(rule.opacity(1.1)))
                        x += step
                    }
                    y += step
                }
            case .grid:
                let step = 17 * unit
                var path = Path()
                var v = step
                while v < size.width { path.addRect(CGRect(x: v, y: 0, width: 0.5, height: size.height)); v += step }
                var h = step
                while h < size.height { path.addRect(CGRect(x: 0, y: h, width: size.width, height: 0.5)); h += step }
                context.fill(path, with: .color(rule.opacity(0.8)))
            }

            // Cover band
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 6 * unit)), with: .color(tint))

            // Placeholder handwriting
            let widths = barWidths
            let inset = 18 * unit
            let usable = size.width - 2 * inset
            let heading = CGRect(x: inset, y: 34 * unit, width: usable * widths[0], height: 8 * unit)
            context.fill(Path(roundedRect: heading, cornerRadius: 4 * unit), with: .color(tint.opacity(0.85)))
            for (i, fraction) in widths.dropFirst().enumerated() {
                let bar = CGRect(x: inset, y: (68 + CGFloat(i) * 16) * unit, width: usable * fraction, height: 6 * unit)
                context.fill(Path(roundedRect: bar, cornerRadius: 3 * unit), with: .color(tint.opacity(0.5)))
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
                .aspectRatio(0.97, contentMode: .fit)
                .frame(width: 190)
        }
    }
    .padding()
}
