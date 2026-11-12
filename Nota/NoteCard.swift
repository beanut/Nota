import NotaUI
import SwiftUI

/// Figma **Note Card**: a paper thumbnail on the desk, then title and detail.
struct NoteCard: View {
    let note: Note
    @Environment(ThumbnailStore.self) private var thumbnails
    @State private var loadedCover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: NotaSpacing.sm) {
            let shape = RoundedRectangle(cornerRadius: NotaRadius.paper, style: .continuous)
            // The memory cache first, so a card scrolled back into view shows its ink without a flash.
            PaperThumbnail(paper: note.paper, cover: thumbnails.cachedImage(for: note.id) ?? loadedCover)
                .aspectRatio(PaperThumbnail.aspectRatio, contentMode: .fit)
                .clipShape(shape)
                .overlay(alignment: .bottomTrailing) { badges }
                .notaElevation(.paper)
                .contentShape(.contextMenuPreview, shape)
                .task(id: thumbnails.generation(for: note.id)) {
                    loadedCover = await thumbnails.image(for: note.id)
                }

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

/// Figma **Paper** in miniature: the note's cover page as rendered by `ThumbnailStore` (paper template and
/// ink), or the bare template while the cover loads or when the note has no ink yet.
struct PaperThumbnail: View {
    let paper: PaperStyle
    var cover: UIImage?

    /// US Letter, as in Figma (190 × 246).
    static let aspectRatio: CGFloat = 190.0 / 246.0

    var body: some View {
        ZStack(alignment: .top) {
            if let cover {
                // Covers keep their page's proportions; a page that isn't Letter-shaped sits on plain paper.
                NotaColor.paperSurface
                Image(uiImage: cover)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    context.withCGContext { PaperTemplate.draw(paper, in: $0, size: size) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 24) {
        ForEach(PaperStyle.allCases) { paper in
            PaperThumbnail(paper: paper)
                .aspectRatio(PaperThumbnail.aspectRatio, contentMode: .fit)
                .frame(width: 190)
        }
    }
    .padding()
}
