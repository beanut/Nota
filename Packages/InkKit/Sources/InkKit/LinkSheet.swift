import SwiftUI

/// What the host tells the editor so links can go to other notes, and come back. InkKit doesn't know about
/// notes: it shows these in the link sheet and hands `.note` links to `open`.
///
/// ```swift
/// InkCanvasEditor(notebook: notebook, links: NoteLinks(
///     notes: otherNotes.map { PageDestination(id: $0.id, title: $0.title) },
///     pages: { id in await store.pageIDs(of: id) },
///     open: { note, page in router.open(note, at: page) },
///     back: router.cameFrom.map { LinkBack(title: $0.title) { router.goBack() } }
/// ))
/// ```
public struct NoteLinks {
    /// The other notes a link can go to, in the order the link sheet lists them.
    public var notes: [PageDestination]
    /// The ids of a note's pages in order, for linking to one of them. Empty when it can't be read.
    public var pages: @MainActor (UUID) async -> [UUID]
    /// Opens a note, at the page if one is given, when a link to it is followed.
    public var open: @MainActor (UUID, UUID?) -> Void
    /// Where Back goes once there's no page left to go back to in this note: the note a link came from.
    public var back: LinkBack?

    public init(notes: [PageDestination], pages: @escaping @MainActor (UUID) async -> [UUID],
                open: @escaping @MainActor (UUID, UUID?) -> Void, back: LinkBack? = nil) {
        self.notes = notes
        self.pages = pages
        self.open = open
        self.back = back
    }
}

/// Going back to where a link was followed from, in another note.
public struct LinkBack {
    /// What Back says it returns to, e.g. the note's title.
    public var title: String
    public var action: @MainActor () -> Void

    public init(title: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.action = action
    }
}

// MARK: - Choosing where a link goes

/// The sheet Add Link… and Edit Link… open: a web address, a page of this note, or another note (the note
/// itself or one of its pages).
struct LinkSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case web = "Web", page = "This Note", note = "Another Note"

        var id: String {
            rawValue
        }
    }

    @ObservedObject var notebook: InkNotebook
    let request: LinkRequest
    let links: NoteLinks?
    let onDone: (LinkTarget, String?) -> Void
    let onCancel: () -> Void

    @State private var kind: Kind = .page
    @State private var address = ""
    @State private var pageID: UUID?
    @State private var noteID: UUID?
    /// The chosen note's pages, once read; the chosen page among them (nil for the note itself).
    @State private var notePages: [UUID]?
    @State private var notePageID: UUID?
    @Environment(\.inkTheme) private var theme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Link to", selection: $kind) {
                        ForEach(kinds) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch kind {
                case .web: webSection
                case .page: pageSection
                case .note: noteSection
                }
            }
            .navigationTitle(request.linkID == nil ? "Add Link" : "Edit Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.linkID == nil ? "Add" : "Done") {
                        if let target = chosenTarget {
                            onDone(target, title(for: target))
                        }
                    }
                    .disabled(chosenTarget == nil)
                }
            }
        }
        .tint(theme.color(\.accent))
        .onAppear(perform: start)
        .task(id: noteID) { await loadNotePages() }
    }

    private var kinds: [Kind] {
        links == nil ? [.web, .page] : Kind.allCases
    }

    // MARK: Sections

    private var webSection: some View {
        Section {
            TextField("example.com", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit {
                    if let target = chosenTarget {
                        onDone(target, title(for: target))
                    }
                }
        } footer: {
            if !address.isEmpty, LinkTarget.web(address) == nil {
                Text("Enter a web address, like example.com.")
            } else {
                Text("Tapping the link opens the page in your browser.")
            }
        }
    }

    private var pageSection: some View {
        Section {
            ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                choiceRow(title: "Page \(index + 1)", detail: pageDetail(page.id, index: index),
                          isChosen: pageID == page.id) { pageID = page.id }
            }
        } footer: {
            Text("Back returns to this page after the link is followed.")
        }
    }

    @ViewBuilder
    private var noteSection: some View {
        let notes = links?.notes ?? []
        if notes.isEmpty {
            Section {
                Text("There are no other notes to link to.")
                    .foregroundStyle(theme.color(\.textSecondary))
            }
        } else {
            Section("Note") {
                Picker("Note", selection: chosenNote) {
                    Text("Choose a Note").tag(UUID?.none)
                    ForEach(notes) { note in
                        Text(note.title.isEmpty ? "Untitled" : note.title).tag(UUID?.some(note.id))
                    }
                }
                .pickerStyle(.menu)
                .font(theme.bodyFont)
            }
            if noteID != nil {
                Section("Page") {
                    choiceRow(title: "Where it was last open", detail: nil, isChosen: notePageID == nil) {
                        notePageID = nil
                    }
                    if let notePages {
                        ForEach(Array(notePages.enumerated()), id: \.element) { index, id in
                            choiceRow(title: "Page \(index + 1)", detail: nil, isChosen: notePageID == id) {
                                notePageID = id
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
    }

    private func choiceRow(title: String, detail: String?, isChosen: Bool,
                           choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: InkSpacing.s) {
                VStack(alignment: .leading, spacing: InkSpacing.xxxs) {
                    Text(title)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.color(\.textPrimary))
                    if let detail {
                        Text(detail)
                            .font(theme.footnoteFont)
                            .foregroundStyle(theme.color(\.textSecondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.color(\.accent))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// "This page", the page's outline titles and whether it's bookmarked.
    private func pageDetail(_ id: UUID, index: Int) -> String? {
        var parts: [String] = []
        if index == notebook.pages.firstIndex(where: { $0.id == request.pageID }) {
            parts.append("This page")
        }
        if notebook.isBookmarked(id) {
            parts.append("Bookmarked")
        }
        parts += notebook.outline.entries.filter { $0.pageID == id }.map(\.title)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: State

    /// The note picked in the menu; choosing another one forgets the page chosen in the last.
    private var chosenNote: Binding<UUID?> {
        Binding {
            noteID
        } set: { id in
            if id != noteID {
                noteID = id
                notePageID = nil
            }
        }
    }

    private var chosenTarget: LinkTarget? {
        switch kind {
        case .web: LinkTarget.web(address)
        case .page: pageID.map(LinkTarget.page)
        case .note: noteID.map { LinkTarget.note($0, page: notePageID) }
        }
    }

    /// What the link is called in menus and to VoiceOver.
    private func title(for target: LinkTarget) -> String? {
        switch target {
        case let .url(url):
            return url.host ?? url.absoluteString
        case let .page(id):
            return notebook.index(of: id).map { "Page \($0 + 1)" }
        case let .note(id, page):
            let name = links?.notes.first { $0.id == id }?.title ?? "Note"
            guard let page, let index = notePages?.firstIndex(of: page) else { return name }
            return "\(name), page \(index + 1)"
        }
    }

    /// Starts on the link's current target, or on the next page of this note for a new link.
    private func start() {
        switch request.target {
        case let .url(url)?:
            kind = .web
            address = url.absoluteString
        case let .page(id)?:
            kind = .page
            pageID = id
        case let .note(id, page)?:
            kind = links == nil ? .page : .note
            noteID = id
            notePageID = page
        case nil:
            let here = notebook.index(of: request.pageID) ?? notebook.currentPageIndex
            pageID = notebook.pages[min(here + 1, notebook.pageCount - 1)].id
        }
    }

    private func loadNotePages() async {
        guard let noteID, let links else { return }
        notePages = nil
        let pages = await links.pages(noteID)
        guard noteID == self.noteID else { return }
        notePages = pages
    }
}

// MARK: - Back

/// The floating Back button shown after a link was followed: back to the page it was followed from, or to
/// the note it came from (`NoteLinks.back`).
struct LinkBackButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: InkSpacing.xxs) {
                InkIconView(.back, size: 14)
                Text("Back to \(title)")
                    .font(theme.footnoteEmphasizedFont)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.color(\.textPrimary))
            .padding(.horizontal, InkSpacing.m)
            .frame(height: InkMetrics.iconButton.height)
            .inkFloatingBar(fill: \.surfaceRaised)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(title)")
    }
}
