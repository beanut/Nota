import InkKit
import NotaCore
import NotaDocuments
import NotaUI
import SwiftData
import SwiftUI

/// The detail column: filter chips, a grid of note cards, search and the New Note button.
struct NotesBrowser: View {
    let section: LibrarySection
    @Binding var path: [Note]

    @Environment(\.modelContext) private var modelContext
    @Environment(DocumentStore.self) private var documents
    @Environment(ThumbnailStore.self) private var thumbnails
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @State private var filter: LibraryFilter = .recent
    @State private var searchText = ""
    @State private var noteBeingRenamed: Note?
    @State private var renameText = ""
    @State private var notePendingDeletion: Note?
    @State private var isConfirmingEmptyTrash = false
    @State private var isChoosingNewNotePaper = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: NotaSpacing.xxl, alignment: .top)]

    private var folder: Folder? {
        guard case let .folder(id) = section else { return nil }
        return folders.first { $0.persistentModelID == id }
    }

    private var title: String {
        folder?.name ?? section.title
    }

    private var visibleNotes: [Note] {
        Library.visibleNotes(allNotes, in: section, filter: filter, search: searchText)
    }

    var body: some View {
        let notes = visibleNotes
        ScrollView {
            VStack(alignment: .leading, spacing: NotaSpacing.xl) {
                filterBar

                LazyVGrid(columns: columns, alignment: .leading, spacing: NotaSpacing.xxl) {
                    ForEach(notes) { note in
                        card(for: note)
                    }
                }
            }
            .padding(.horizontal, NotaSpacing.xxl)
            .padding(.bottom, NotaSpacing.xxxl)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(NotaColor.bgApp)
        .overlay {
            if notes.isEmpty {
                emptyState
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search notes")
        .toolbar { toolbarContent }
        .alert("Rename Note", isPresented: isPresent($noteBeingRenamed)) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    noteBeingRenamed?.title = name
                }
            }
        }
        .confirmationDialog("Delete “\(notePendingDeletion?.title ?? "")” permanently?",
                            isPresented: isPresent($notePendingDeletion),
                            titleVisibility: .visible) {
            Button("Delete Note", role: .destructive) {
                if let note = notePendingDeletion {
                    purge([note])
                }
            }
        } message: {
            Text("This can’t be undone.")
        }
        .sheet(isPresented: $isChoosingNewNotePaper) {
            NewNoteSheet(onCreate: createNote)
        }
        .confirmationDialog("Delete all notes in Recently Deleted?",
                            isPresented: $isConfirmingEmptyTrash,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                purge(allNotes.filter(\.isDeleted))
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    // MARK: Pieces

    private var filterBar: some View {
        HStack(spacing: NotaSpacing.s) {
            ForEach(LibraryFilter.allCases) { option in
                Button(option.title) { filter = option }
                    .buttonStyle(.notaChip(selected: option == filter))
                    .accessibilityAddTraits(option == filter ? .isSelected : [])
            }
        }
        .animation(.snappy, value: filter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter")
    }

    @ViewBuilder
    private func card(for note: Note) -> some View {
        if section == .deleted {
            NoteCard(note: note)
                .contextMenu { deletedNoteMenu(for: note) }
        } else {
            NavigationLink(value: note) {
                NoteCard(note: note)
            }
            .buttonStyle(.plain)
            .contextMenu { noteMenu(for: note) }
        }
    }

    /// Why the grid is empty, from the most specific reason to the least.
    @ViewBuilder
    private var emptyState: some View {
        let inSection = allNotes.contains { section.contains($0) }
        if !searchText.isEmpty {
            NotaEmptyState(.search, title: "No Results", message: "No notes match “\(searchText)”.")
        } else if inSection, filter == .pdfs {
            NotaEmptyState(.filter, title: "No PDFs", message: "PDFs you import will appear here.")
        } else if inSection, filter == .notebooks {
            NotaEmptyState(.filter, title: "No Notebooks", message: "Only PDFs are in \(title).")
        } else {
            switch section {
            case .deleted:
                NotaEmptyState(.trash, title: "Nothing in Recently Deleted",
                               message: "Deleted notes stay here until you remove them.")
            case .favorites:
                NotaEmptyState(.star, title: "No Favorites", message: "Favorite a note from its menu to keep it here.")
            case .recents:
                NotaEmptyState(.clock, title: "No Recent Notes", message: "Notes you’ve edited in the last 7 days appear here.")
            case .shared:
                NotaEmptyState(.share, title: "No Shared Notes", message: "Notes you share appear here.")
            case .folder:
                NotaEmptyState(.folder, title: "This Folder Is Empty",
                               message: "Create a note here, or move one in from its menu.") { newNoteButton(size: .large) }
            case .all:
                NotaEmptyState(.grid, title: "No Notes Yet",
                               message: "Notes you create will appear here.") { newNoteButton(size: .large) }
            }
        }
    }

    private func newNoteButton(size: NotaButtonStyle.Size) -> some View {
        Button { isChoosingNewNotePaper = true } label: {
            NotaButtonLabel("New Note", icon: .plus, size: size)
        }
        .buttonStyle(.nota(.primary, size: size))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if section == .deleted {
                Button("Delete All", role: .destructive) { isConfirmingEmptyTrash = true }
                    .disabled(!allNotes.contains(where: \.isDeleted))
            } else {
                newNoteButton(size: .compact)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func noteMenu(for note: Note) -> some View {
        Button {
            note.isFavorite.toggle()
        } label: {
            note.isFavorite
                ? Label("Unfavorite", systemImage: "star.slash")
                : Label("Favorite", systemImage: "star")
        }
        Button {
            renameText = note.title
            noteBeingRenamed = note
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Menu {
            Picker("Folder", selection: Binding(get: { note.folder }, set: { note.folder = $0 })) {
                Text("None").tag(Folder?.none)
                ForEach(folders) { folder in
                    Label(folder.name, systemImage: "folder").tag(Optional(folder))
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
        Menu {
            Picker("Template", selection: Binding(get: { note.template.preset }, set: { preset in
                if let preset {
                    setTemplate(preset.template.on(note.template.paper), of: note)
                }
            })) {
                ForEach(PageTemplate.Preset.allCases) { Text($0.title).tag(Optional($0)) }
            }
            Picker("Paper", selection: Binding(get: { note.template.paper }, set: { paper in
                var template = note.template.on(paper)
                template.background = nil
                setTemplate(template, of: note)
            })) {
                ForEach(PaperColor.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Template", systemImage: "paintpalette")
        }
        Button {
            duplicate(note)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        ShareLink(item: note.title) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            withAnimation { note.moveToRecentlyDeleted() }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func deletedNoteMenu(for note: Note) -> some View {
        Button {
            withAnimation { note.recover() }
        } label: {
            Label("Recover", systemImage: "arrow.uturn.backward")
        }
        Button(role: .destructive) {
            notePendingDeletion = note
        } label: {
            Label("Delete Permanently", systemImage: "trash")
        }
    }

    // MARK: Actions

    private func createNote(template: PageTemplate, size: PageSize) {
        let note = Note(title: String(localized: "Untitled Note"),
                        template: template,
                        tint: folder.map { NoteTint.allCases[$0.sortIndex % NoteTint.allCases.count] } ?? .indigo,
                        isFavorite: section == .favorites,
                        folder: folder)
        modelContext.insert(note)
        documents.create(note, size: size, template: template)
        try? modelContext.save()
        searchText = ""
        path.append(note)
    }

    /// Puts every page on `template`. The cover is rendered on its template, so a note with ink gets a new
    /// cover.
    private func setTemplate(_ template: PageTemplate, of note: Note) {
        documents.setTemplate(template, of: note)
        if let notebook = documents.existingNotebook(for: note.id) {
            thumbnails.updateCover(of: note.id, page: notebook.pages[0].snapshot())
        }
    }

    private func duplicate(_ note: Note) {
        let copy = Note(title: String(localized: "\(note.title) Copy"),
                        pageCount: note.pageCount,
                        template: note.template,
                        tint: note.tint,
                        kind: note.kind,
                        folder: note.folder)
        documents.duplicate(note, as: copy)
        withAnimation { modelContext.insert(copy) }
    }

    private func purge(_ notes: [Note]) {
        withAnimation {
            for note in notes {
                documents.discard(noteID: note.id)
                thumbnails.remove(noteID: note.id)
                modelContext.delete(note)
            }
        }
    }
}
