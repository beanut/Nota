import SwiftUI

/// The page sidebar's Outline tab: the note's bookmarked pages, its own outline entries (added, renamed,
/// reordered and deleted here) and the outline of any PDF brought into it, nested as the PDF has it. Tap a
/// row to go to its page.
struct OutlinePanel: View {
    @ObservedObject var notebook: InkNotebook

    @State private var naming: Naming?
    @State private var name = ""
    @Environment(\.inkTheme) private var theme

    /// Adding an entry for a page, or renaming one.
    private enum Naming: Identifiable {
        case add(UUID)
        case rename(NoteOutline.Entry)

        var id: UUID {
            switch self {
            case let .add(page): page
            case let .rename(entry): entry.id
            }
        }
    }

    var body: some View {
        let pageIDs = notebook.pages.map(\.id)
        let outline = notebook.outline
        let bookmarks = outline.bookmarkedPages(in: pageIDs)
        let custom = outline.resolved(outline.customEntries, in: pageIDs)
        let pdf = outline.resolved(outline.pdfEntries, in: pageIDs)
        List {
            Section {
                ForEach(bookmarks) { item in
                    row(title: "Page \(item.pageIndex + 1)", page: item.pageIndex, icon: .bookmark)
                        .contextMenu {
                            Button { notebook.toggleBookmark(item.value) } label: {
                                Label("Remove Bookmark", systemImage: "bookmark.slash")
                            }
                        }
                }
                if bookmarks.isEmpty {
                    hint("Bookmark a page with the bookmark button in the page bar.")
                }
            } header: {
                sectionHeader("Bookmarks")
            }

            Section {
                ForEach(custom) { item in
                    row(title: item.value.title, page: item.pageIndex, icon: nil)
                        .contextMenu {
                            Button { startNaming(.rename(item.value)) } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Button(role: .destructive) { notebook.removeOutlineEntry(item.value.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onMove { notebook.moveCustomOutlineEntries(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    for i in offsets {
                        notebook.removeOutlineEntry(custom[i].value.id)
                    }
                }
                Button { startNaming(.add(notebook.currentPage.id)) } label: {
                    Label("Add This Page", systemImage: "plus")
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.color(\.accent))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            } header: {
                sectionHeader("Outline")
            }

            if !pdf.isEmpty {
                Section {
                    ForEach(pdf) { item in
                        row(title: item.value.title.isEmpty ? "Untitled" : item.value.title, page: item.pageIndex,
                            icon: nil, level: item.value.level)
                    }
                } header: {
                    sectionHeader("From PDF")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: {
            if !$0 {
                naming = nil
            }
        })) {
            TextField("Title", text: $name)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(namingConfirmation) { finishNaming() }
        }
    }

    // MARK: Rows

    private func row(title: String, page index: Int, icon: InkIcon?, level: Int = 0) -> some View {
        let isCurrent = index == notebook.currentPageIndex
        return Button {
            notebook.goToPage(index)
        } label: {
            HStack(spacing: InkSpacing.xs) {
                if let icon {
                    InkIconView(icon, size: 14)
                        .foregroundStyle(theme.color(\.accent))
                }
                Text(title)
                    .font(theme.bodyFont)
                    .foregroundStyle(isCurrent ? theme.color(\.accent) : theme.color(\.textPrimary))
                    .lineLimit(2)
                Spacer(minLength: InkSpacing.xxs)
                Text("\(index + 1)")
                    .font(theme.footnoteFont.monospacedDigit())
                    .foregroundStyle(theme.color(\.textSecondary))
            }
            .padding(.leading, CGFloat(min(level, 4)) * InkSpacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: InkSpacing.xs, leading: InkSpacing.m, bottom: InkSpacing.xs, trailing: InkSpacing.m))
        .accessibilityLabel("\(title), page \(index + 1)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(theme.footnoteEmphasizedFont)
            .foregroundStyle(theme.color(\.textSecondary))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(theme.footnoteFont)
            .foregroundStyle(theme.color(\.textTertiary))
            .listRowBackground(Color.clear)
    }

    // MARK: Naming

    private var namingTitle: String {
        switch naming {
        case .rename?: "Rename Entry"
        default: "Add to Outline"
        }
    }

    private var namingConfirmation: String {
        switch naming {
        case .rename?: "Rename"
        default: "Add"
        }
    }

    private func startNaming(_ request: Naming) {
        switch request {
        case let .add(page):
            name = notebook.index(of: page).map { "Page \($0 + 1)" } ?? ""
        case let .rename(entry):
            name = entry.title
        }
        naming = request
    }

    private func finishNaming() {
        switch naming {
        case let .add(page)?:
            notebook.addOutlineEntry(title: name, pageID: page)
        case let .rename(entry)?:
            notebook.renameOutlineEntry(entry.id, to: name)
        case nil:
            break
        }
        naming = nil
    }
}
