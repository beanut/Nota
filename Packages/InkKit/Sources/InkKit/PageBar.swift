import SwiftUI

/// Floating bar under the page: previous / next, the page number, bookmarking the page, adding pages, the page
/// size and template.
struct PageBar: View {
    @ObservedObject var notebook: InkNotebook
    let allowsMultiplePages: Bool
    /// Shows and hides the page sidebar; nil for no sidebar button.
    var showsSidebar: Binding<Bool>?

    @State private var customSizeTarget: CustomSizeTarget?
    @State private var confirmDelete = false
    @Environment(\.inkTheme) private var theme

    var body: some View {
        HStack(spacing: InkSpacing.xxxs) {
            if let showsSidebar {
                Button {
                    withAnimation(.snappy) { showsSidebar.wrappedValue.toggle() }
                } label: {
                    InkIconView(.pages)
                }
                .buttonStyle(.inkIcon(selected: showsSidebar.wrappedValue))
                .accessibilityLabel(showsSidebar.wrappedValue ? "Hide Pages" : "Show Pages")
                InkBarDivider()
            }
            if allowsMultiplePages {
                Button { notebook.goToPreviousPage() } label: { InkIconView(.previousPage) }
                    .buttonStyle(.inkIcon)
                    .disabled(!notebook.canGoToPreviousPage)
                    .accessibilityLabel("Previous page")
                Text("Page \(notebook.currentPageIndex + 1) of \(notebook.pageCount)")
                    .font(theme.bodyEmphasizedFont.monospacedDigit())
                    .foregroundStyle(theme.color(\.textPrimary))
                Button { notebook.goToNextPage() } label: { InkIconView(.nextPage) }
                    .buttonStyle(.inkIcon)
                    .disabled(!notebook.canGoToNextPage)
                    .accessibilityLabel("Next page")
                bookmarkButton
                InkBarDivider()
                addMenu
            }
            sizeMenu
            TemplateMenu(notebook: notebook, allowsMultiplePages: allowsMultiplePages)
        }
        .padding(.leading, InkSpacing.xxs)
        .padding(.trailing, InkSpacing.xs)
        .padding(.vertical, InkSpacing.xxs)
        .inkFloatingBar(fill: \.surfaceRaised)
        .sheet(item: $customSizeTarget) { target in
            CustomPageSizeSheet(initial: target.initial) { size in apply(size, to: target.kind) }
        }
        .confirmationDialog("Delete page \(notebook.currentPageIndex + 1)?", isPresented: $confirmDelete) {
            Button("Delete Page", role: .destructive) {
                notebook.removePage(at: notebook.currentPageIndex)
            }
        } message: {
            Text("Its ink is deleted too. This can't be undone.")
        }
    }

    private var bookmarkButton: some View {
        let id = notebook.currentPage.id
        let isBookmarked = notebook.isBookmarked(id)
        return Button { notebook.toggleBookmark(id) } label: { InkIconView(.bookmark) }
            .buttonStyle(.inkIcon(selected: isBookmarked))
            .accessibilityLabel(isBookmarked ? "Remove Bookmark" : "Bookmark Page")
            .accessibilityAddTraits(isBookmarked ? .isSelected : [])
    }

    private var currentSize: PageSize {
        notebook.currentPage.pageSize
    }

    private var addMenu: some View {
        Menu {
            Button { notebook.addPage() } label: {
                Label("Add Page After", systemImage: "plus.rectangle.portrait")
            }
            Button { notebook.insertPage(at: notebook.currentPageIndex) } label: {
                Label("Add Page Before", systemImage: "plus.rectangle.portrait")
            }
            Menu("Add Page of Size") {
                sizeButtons { notebook.addPage(size: $0) }
                Button("Custom…") { customSizeTarget = CustomSizeTarget(kind: .newPage, initial: currentSize) }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete Page", systemImage: "trash")
            }
            .disabled(!notebook.canRemovePage)
        } label: {
            InkIconView(.addPage)
        } primaryAction: {
            notebook.addPage()
        }
        .menuStyle(.button)
        .buttonStyle(.inkIcon)
        .accessibilityLabel("Add page")
        .accessibilityHint("Touch and hold for more page options.")
    }

    private var sizeMenu: some View {
        Menu {
            Section("This Page · \(currentSize.displayName())") {
                sizeButtons { notebook.setPageSize($0, forPageAt: notebook.currentPageIndex) }
                Button("Custom…") { customSizeTarget = CustomSizeTarget(kind: .currentPage, initial: currentSize) }
            }
            if allowsMultiplePages, notebook.pageCount > 1 {
                Button("Use \(currentSize.displayName()) for All Pages") {
                    notebook.setPageSizeForAllPages(currentSize)
                }
            }
        } label: {
            InkPill(text: currentSize.displayName())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Page size, \(currentSize.displayName())")
    }

    /// Every preset in portrait and landscape, with the current size checked.
    private func sizeButtons(_ choose: @escaping (PageSize) -> Void) -> some View {
        ForEach(PageSize.presets, id: \.self) { preset in
            Menu(preset.displayName()) {
                ForEach([preset.portrait, preset.landscape], id: \.self) { size in
                    Button {
                        choose(size)
                    } label: {
                        if size.hasSameDimensions(as: currentSize) {
                            Label(size.isLandscape ? "Landscape" : "Portrait", systemImage: "checkmark")
                        } else {
                            Text(size.isLandscape ? "Landscape" : "Portrait")
                        }
                    }
                }
            }
        }
    }

    private func apply(_ size: PageSize, to kind: CustomSizeTarget.Kind) {
        switch kind {
        case .currentPage: notebook.setPageSize(size, forPageAt: notebook.currentPageIndex)
        case .newPage: notebook.addPage(size: size)
        }
    }
}

private struct CustomSizeTarget: Identifiable {
    enum Kind { case currentPage, newPage }
    let kind: Kind
    let initial: PageSize
    var id: Kind {
        kind
    }
}

/// Width and height entry for a custom page, in inches, millimetres or points.
public struct CustomPageSizeSheet: View {
    let initial: PageSize
    let onDone: (PageSize) -> Void

    /// Starts from `initial`'s dimensions and calls `onDone` with the size entered.
    public init(initial: PageSize, onDone: @escaping (PageSize) -> Void) {
        self.initial = initial
        self.onDone = onDone
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.inkTheme) private var theme
    @State private var unit = PageSize.Unit.localeDefault
    @State private var width: Double = 0
    @State private var height: Double = 0

    public var body: some View {
        NavigationStack {
            Form {
                Picker("Units", selection: $unit) {
                    ForEach(PageSize.Unit.allCases) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                Section {
                    dimensionField("Width", value: $width)
                    dimensionField("Height", value: $height)
                    Button("Swap Width and Height") { swap(&width, &height) }
                } footer: {
                    let range = unit.allowedRange
                    Text("Each side can be \(format(range.lowerBound))–\(format(range.upperBound)) \(unit.symbol).")
                }
            }
            .navigationTitle("Custom Page Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(PageSize(width: width, height: height, unit: unit))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .onAppear { load(initial, in: unit) }
        .onChange(of: unit) { old, new in
            width = new.fromPoints(old.toPoints(width))
            height = new.fromPoints(old.toPoints(height))
        }
    }

    private var isValid: Bool {
        unit.allowedRange.contains(width) && unit.allowedRange.contains(height)
    }

    private func load(_ size: PageSize, in unit: PageSize.Unit) {
        width = (unit.fromPoints(size.width) * 100).rounded() / 100
        height = (unit.fromPoints(size.height) * 100).rounded() / 100
    }

    private func dimensionField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: value, format: .number.precision(.fractionLength(0 ... 2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(unit.symbol).foregroundStyle(theme.color(\.textSecondary))
            }
        }
    }

    private func format(_ v: CGFloat) -> String {
        Double(v).formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}
