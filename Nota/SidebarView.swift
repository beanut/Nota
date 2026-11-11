import SwiftData
import SwiftUI

struct SidebarView: View {
    @Binding var selection: LibrarySection?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]
    @Query private var notes: [Note]

    @State private var foldersExpanded = true
    @State private var isCreatingFolder = false
    @State private var folderName = ""
    @State private var folderBeingRenamed: Folder?
    @State private var folderPendingDeletion: Folder?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(LibrarySection.smart, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(section == .all ? notes.filter { !$0.isDeleted }.count : 0)
                        .tag(section)
                }
            }

            Section("Folders", isExpanded: $foldersExpanded) {
                ForEach(folders) { folder in
                    Label {
                        Text(folder.name)
                    } icon: {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(folder.color.color)
                    }
                    .badge(folder.activeNoteCount)
                    .tag(LibrarySection.folder(folder.persistentModelID))
                    .contextMenu { folderMenu(for: folder) }
                }
                .onMove(perform: moveFolders)
                .onDelete { offsets in
                    folderPendingDeletion = offsets.first.map { folders[$0] }
                }

                Button {
                    folderName = ""
                    isCreatingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .foregroundStyle(.tint)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create", action: createFolder)
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Enter a name for this folder.")
        }
        .alert("Rename Folder", isPresented: isPresent($folderBeingRenamed)) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = folderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { folderBeingRenamed?.name = name }
            }
        }
        .confirmationDialog("Delete “\(folderPendingDeletion?.name ?? "")”?",
                            isPresented: isPresent($folderPendingDeletion),
                            titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let folder = folderPendingDeletion { delete(folder) }
            }
        } message: {
            Text("Notes in this folder stay in All Notes.")
        }
    }

    @ViewBuilder
    private func folderMenu(for folder: Folder) -> some View {
        Button {
            folderName = folder.name
            folderBeingRenamed = folder
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Menu {
            Picker("Color", selection: Binding(get: { folder.color }, set: { folder.color = $0 })) {
                ForEach(FolderColor.allCases) { color in
                    Text(color.rawValue.capitalized).tag(color)
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        Divider()
        Button(role: .destructive) {
            folderPendingDeletion = folder
        } label: {
            Label("Delete Folder", systemImage: "trash")
        }
    }

    private func createFolder() {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let color = FolderColor.allCases[folders.count % FolderColor.allCases.count]
        let folder = Folder(name: name, color: color, sortIndex: (folders.map(\.sortIndex).max() ?? -1) + 1)
        modelContext.insert(folder)
        try? modelContext.save()
        selection = .folder(folder.persistentModelID)
    }

    private func delete(_ folder: Folder) {
        if selection == .folder(folder.persistentModelID) { selection = .all }
        modelContext.delete(folder)
    }

    private func moveFolders(from source: IndexSet, to destination: Int) {
        var reordered = folders
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, folder) in reordered.enumerated() { folder.sortIndex = index }
    }
}

/// A Bool binding that is true while `item` is non-nil, and clears it on dismissal.
func isPresent<T>(_ item: Binding<T?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}
