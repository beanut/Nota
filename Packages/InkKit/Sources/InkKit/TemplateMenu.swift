import SwiftUI
import UniformTypeIdentifiers

/// The page bar's template pill: the current page's template and paper, the built-ins, a custom
/// background from any PDF or image, and applying the current page's template to every page.
struct TemplateMenu: View {
    @ObservedObject var notebook: InkNotebook
    let allowsMultiplePages: Bool

    @State private var isImporting = false
    @State private var importFailed = false
    @Environment(\.inkTheme) private var theme

    private var page: CanvasDocument {
        notebook.currentPage
    }

    private var template: PageTemplate {
        page.template
    }

    var body: some View {
        Menu {
            Section("This Page · \(template.title)") {
                ForEach(PageTemplate.Preset.allCases) { preset in
                    Button {
                        set(preset.template.on(template.paper))
                    } label: {
                        if template.preset == preset {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
                Button("PDF or Image…") { isImporting = true }
            }
            Menu("Paper · \(template.paper.title)") {
                ForEach(PaperColor.allCases) { paper in
                    Button {
                        notebook.setTemplate(template.on(paper), artwork: page.templateArtwork,
                                             forPageAt: notebook.currentPageIndex)
                    } label: {
                        if template.paper == paper {
                            Label(paper.title, systemImage: "checkmark")
                        } else {
                            Text(paper.title)
                        }
                    }
                }
            }
            if allowsMultiplePages, notebook.pageCount > 1 {
                Button("Use \(template.title) for All Pages") {
                    notebook.setTemplateForAllPages(template, artwork: page.templateArtwork)
                }
            }
        } label: {
            InkPill(text: template.title)
        }
        .menuStyle(.button)
        .menuOrder(.fixed) // it opens upwards; keep the list in reading order
        .buttonStyle(.plain)
        .accessibilityLabel("Page template, \(template.title)")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf, .image]) { result in
            guard case let .success(url) = result else { return }
            useBackground(at: url)
        }
        .alert("Couldn't Use This File", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a PDF or an image to use as the page's template.")
        }
    }

    private func set(_ template: PageTemplate) {
        notebook.setTemplate(template, forPageAt: notebook.currentPageIndex)
    }

    /// Puts the current page on the file's first page (a PDF) or the image, on blank paper.
    private func useBackground(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url), let artwork = TemplateArtwork(data: data) else {
            importFailed = true
            return
        }
        var custom = PageTemplate.blank.on(template.paper)
        custom.background = artwork.background
        notebook.setTemplate(custom, artwork: artwork, forPageAt: notebook.currentPageIndex)
    }
}

/// Figma: the page bar's pill (paper size, template): a label and a disclosure chevron on a capsule.
struct InkPill: View {
    let text: String
    @Environment(\.inkTheme) private var theme

    var body: some View {
        HStack(spacing: InkSpacing.xxs) {
            Text(text)
                .font(theme.footnoteEmphasizedFont)
            InkIconView(.disclosure, size: 12)
        }
        .foregroundStyle(theme.color(\.textPrimary))
        .padding(.leading, InkSpacing.sm)
        .padding(.trailing, InkSpacing.s)
        .frame(height: 28)
        .background(theme.color(\.surfaceFill), in: Capsule())
        .contentShape(Capsule())
    }
}
