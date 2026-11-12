import SwiftData
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case recent, notebooks, pdfs
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .notebooks: "Notebooks"
        case .pdfs: "PDFs"
        }
    }

    func contains(_ note: Note) -> Bool {
        switch self {
        case .recent: true
        case .notebooks: note.kind == .notebook
        case .pdfs: note.kind == .pdf
        }
    }
}

/// The detail column: filter chips, a grid of note cards, search and the New Note button.
struct NotesBrowser: View {
    let section: LibrarySection
    @Binding var path: [Note]

    @Environment(\.modelContext) private var modelContext
    @Environment(InkStore.self) private var inkStore
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @State private var filter: LibraryFilter = .recent
    @State private var searchText = ""
    @State private var noteBeingRenamed: Note?
    @State private var renameText = ""
    @State private var notePendingDeletion: Note?
    @State private var isConfirmingEmptyTrash = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 24, alignment: .top)]

    private var folder: Folder? {
        guard case let .folder(id) = section else { return nil }
        return folders.first { $0.persistentModelID == id }
    }

    private var title: String {
        folder?.name ?? section.title
    }

    private var visibleNotes: [Note] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return allNotes.filter { note in
            section.contains(note)
                && filter.contains(note)
                && (query.isEmpty || note.title.localizedStandardContains(query))
        }
    }

    var body: some View {
        let notes = visibleNotes
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                filterBar

                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(notes) { note in
                        card(for: note)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemGroupedBackground))
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
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases) { option in
                if option == filter {
                    Button(option.title) { filter = option }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(.label))
                        .foregroundStyle(Color(.systemBackground))
                } else {
                    Button(option.title) { filter = option }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonBorderShape(.capsule)
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

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if section == .deleted {
            ContentUnavailableView("No Recently Deleted Notes", systemImage: "trash",
                                   description: Text("Deleted notes stay here until you remove them."))
        } else {
            ContentUnavailableView {
                Label("No Notes", systemImage: "square.and.pencil")
            } description: {
                Text("Notes you create will appear here.")
            } actions: {
                Button("New Note", action: createNote)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if section == .deleted {
                Button("Delete All", role: .destructive) { isConfirmingEmptyTrash = true }
                    .disabled(!allNotes.contains(where: \.isDeleted))
            } else {
                Button(action: createNote) {
                    // Text with an inline symbol: toolbars collapse a `Label` to its icon.
                    Text("\(Image(systemName: "plus")) New Note")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 4)
                }
                .accessibilityLabel("New Note")
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
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
            Picker("Paper", selection: Binding(get: { note.paper }, set: { note.paper = $0 })) {
                ForEach(PaperStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Cover", selection: Binding(get: { note.tint }, set: { note.tint = $0 })) {
                ForEach(NoteTint.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
        } label: {
            Label("Appearance", systemImage: "paintpalette")
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
            withAnimation { note.deletedAt = .now }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func deletedNoteMenu(for note: Note) -> some View {
        Button {
            withAnimation { note.deletedAt = nil }
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

    private func createNote() {
        let note = Note(title: String(localized: "Untitled Note"),
                        paper: .lined,
                        tint: folder.map { NoteTint.allCases[$0.sortIndex % NoteTint.allCases.count] } ?? .indigo,
                        isFavorite: section == .favorites,
                        folder: folder)
        modelContext.insert(note)
        try? modelContext.save()
        searchText = ""
        path.append(note)
    }

    private func duplicate(_ note: Note) {
        let copy = Note(title: String(localized: "\(note.title) Copy"),
                        pageCount: note.pageCount,
                        paper: note.paper,
                        tint: note.tint,
                        kind: note.kind,
                        folder: note.folder)
        withAnimation { modelContext.insert(copy) }
    }

    private func purge(_ notes: [Note]) {
        withAnimation {
            for note in notes {
                inkStore.discard(noteID: note.id)
                modelContext.delete(note)
            }
        }
    }
}
