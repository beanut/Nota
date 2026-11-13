import InkKit
import NotaCore
import NotaUI
import SwiftUI

/// Chooses the template, paper and page size of a new note. Remembers the last choice for the next note.
struct NewNoteSheet: View {
    let onCreate: (PageTemplate, PageSize) -> Void

    @Environment(\.dismiss) private var dismiss
    /// `PageTemplate.encodedString`; before templates this key held a paper name, which reads the same way.
    @AppStorage("newNotePaper") private var storedTemplate = ""
    @State private var template = PageTemplate.noteDefault
    @AppStorage("newNotePageSize") private var storedSize = ""
    @State private var size: PageSize = .localeDefault
    @State private var isEnteringCustomSize = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    templatePicker
                    Picker("Paper", selection: $template.paper) {
                        ForEach(PaperColor.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
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
                        storedTemplate = template.encodedString
                        onCreate(template, size)
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
            if let remembered = PageTemplate(encodedString: storedTemplate), remembered.background == nil {
                template = remembered
            }
        }
    }

    /// Every built-in, drawn on the chosen paper.
    private var templatePicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NotaSpacing.l), count: 5),
                  spacing: NotaSpacing.l) {
            ForEach(PageTemplate.Preset.allCases) { preset in
                let isSelected = template.preset == preset
                Button {
                    template = preset.template.on(template.paper)
                } label: {
                    VStack(spacing: NotaSpacing.xs) {
                        PaperThumbnail(template: preset.template.on(template.paper))
                            .aspectRatio(PaperThumbnail.aspectRatio, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: NotaRadius.paper, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: NotaRadius.paper, style: .continuous)
                                    .strokeBorder(isSelected ? NotaColor.accentInk : NotaColor.borderCard,
                                                  lineWidth: isSelected ? 2 : 1)
                            }
                        Text(preset.title)
                            .font(NotaFont.footnoteEmph)
                            .foregroundStyle(isSelected ? NotaColor.textInk : NotaColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
