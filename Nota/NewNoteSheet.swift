import InkKit
import NotaCore
import NotaUI
import SwiftUI

/// Chooses the paper and page size of a new note. Remembers the last choice for the next note.
struct NewNoteSheet: View {
    let onCreate: (PaperStyle, PageSize) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("newNotePaper") private var paper: PaperStyle = .lined
    @AppStorage("newNotePageSize") private var storedSize = ""
    @State private var size: PageSize = .localeDefault
    @State private var isEnteringCustomSize = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Paper") {
                    paperPicker
                }
                Section("Page Size") {
                    Picker("Size", selection: presetBinding) {
                        ForEach(PageSize.presets, id: \.self) { Text($0.displayName()).tag(Optional($0)) }
                        if size.isCustom {
                            Text(size.displayName()).tag(PageSize?.none)
                        }
                    }
                    Picker("Orientation", selection: landscapeBinding) {
                        Text("Portrait").tag(false)
                        Text("Landscape").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Button("Custom Size…") { isEnteringCustomSize = true }
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        storedSize = Self.encode(size)
                        onCreate(paper, size)
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $isEnteringCustomSize) {
            CustomPageSizeSheet(initial: size) { size = $0 }
        }
        .onAppear {
            if let remembered = Self.decode(storedSize) {
                size = remembered
            }
        }
    }

    private var paperPicker: some View {
        HStack(spacing: NotaSpacing.l) {
            ForEach(PaperStyle.allCases) { style in
                Button {
                    paper = style
                } label: {
                    VStack(spacing: NotaSpacing.xs) {
                        PaperThumbnail(paper: style)
                            .aspectRatio(PaperThumbnail.aspectRatio, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: NotaRadius.paper, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: NotaRadius.paper, style: .continuous)
                                    .strokeBorder(style == paper ? NotaColor.accentInk : NotaColor.borderCard,
                                                  lineWidth: style == paper ? 2 : 1)
                            }
                        Text(style.title)
                            .font(NotaFont.footnoteEmph)
                            .foregroundStyle(style == paper ? NotaColor.textInk : NotaColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(style == paper ? .isSelected : [])
            }
        }
        .padding(.vertical, NotaSpacing.s)
    }

    /// The preset the size is, in portrait; nil for a custom size.
    private var presetBinding: Binding<PageSize?> {
        Binding {
            PageSize.presets.first { $0.hasSameDimensions(as: size.portrait) }
        } set: { preset in
            guard let preset else { return }
            size = size.isLandscape ? preset.landscape : preset.portrait
        }
    }

    private var landscapeBinding: Binding<Bool> {
        Binding { size.isLandscape } set: { size = $0 ? size.landscape : size.portrait }
    }

    private static func encode(_ size: PageSize) -> String {
        (try? JSONEncoder().encode(size)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func decode(_ string: String) -> PageSize? {
        try? JSONDecoder().decode(PageSize.self, from: Data(string.utf8))
    }
}

#Preview {
    NewNoteSheet { _, _ in }
}
