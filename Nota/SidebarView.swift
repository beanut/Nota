import NotaCore
import NotaUI
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
        List {
            Section {
                ForEach(LibrarySection.smart, id: \.self) { section in
                    row(for: section, title: section.title,
                        count: section == .all ? notes.filter { !$0.isDeleted }.count : nil) {
                            NotaIconView(section.icon).foregroundStyle(NotaColor.textInk)
                        }
                }
            }

            Section("Folders", isExpanded: $foldersExpanded) {
                ForEach(folders) { folder in
                    row(for: .folder(folder.persistentModelID), title: folder.name, count: folder.activeNoteCount) {
                        NotaIconView(.folder).foregroundStyle(folder.color.color)
                    }
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
                    HStack(spacing: NotaSpacing.m) {
                        NotaIconView(.plus)
                        Text("New Folder").font(NotaFont.calloutEmph)
                    }
                    .foregroundStyle(NotaColor.textInk)
                    .padding(.horizontal, NotaSpacing.m)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarRowChrome()
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(NotaColor.bgApp)
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
                if !name.isEmpty {
                    folderBeingRenamed?.name = name
                }
            }
        }
        .confirmationDialog("Delete “\(folderPendingDeletion?.name ?? "")”?",
                            isPresented: isPresent($folderPendingDeletion),
                            titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let folder = folderPendingDeletion {
                    delete(folder)
                }
            }
        } message: {
            Text("Notes in this folder stay in All Notes.")
        }
    }

    private func row(for section: LibrarySection, title: String, count: Int?,
                     @ViewBuilder icon: () -> some View) -> some View {
        Button {
            selection = section
        } label: {
            SidebarRow(title: title, count: count, isSelected: selection == section, icon: icon())
        }
        .buttonStyle(.plain)
        .sidebarRowChrome()
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
        if selection == .folder(folder.persistentModelID) {
            selection = .all
        }
        modelContext.delete(folder)
    }

    private func moveFolders(from source: IndexSet, to destination: Int) {
        var reordered = folders
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, folder) in reordered.enumerated() {
            folder.sortIndex = index
        }
    }
}

/// Figma **Sidebar Row**: 44 pt, icon · title · count. Selected = ink tint.
private struct SidebarRow<Icon: View>: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let icon: Icon

    var body: some View {
        HStack(spacing: NotaSpacing.m) {
            icon
            Text(title)
                .font(isSelected ? NotaFont.calloutEmph : NotaFont.callout)
                .foregroundStyle(isSelected ? NotaColor.textInk : NotaColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(NotaFont.subheadline)
                    .foregroundStyle(NotaColor.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NotaSpacing.m)
        .frame(minHeight: 44)
        .background(isSelected ? NotaColor.bgInkTint : .clear,
                    in: RoundedRectangle(cornerRadius: NotaRadius.control, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private extension View {
    /// Rows draw their own selection, so the list's background, separators and insets step aside.
    func sidebarRowChrome() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: NotaSpacing.s, bottom: 0, trailing: NotaSpacing.s))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A Bool binding that is true while `item` is non-nil, and clears it on dismissal.
func isPresent(_ item: Binding<(some Any)?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: {
        if !$0 {
            item.wrappedValue = nil
        }
    })
}
