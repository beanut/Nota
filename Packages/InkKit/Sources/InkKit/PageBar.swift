import SwiftUI

/// Floating bar under the page: previous / next, the page number, adding pages and the page size.
struct PageBar: View {
    @ObservedObject var notebook: InkNotebook
    let allowsMultiplePages: Bool

    @State private var customSizeTarget: CustomSizeTarget?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 4) {
            if allowsMultiplePages {
                iconButton("chevron.left", "Previous page", enabled: notebook.canGoToPreviousPage) {
                    notebook.goToPreviousPage()
                }
                Text("\(notebook.currentPageIndex + 1) of \(notebook.pageCount)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 64)
                    .accessibilityLabel("Page \(notebook.currentPageIndex + 1) of \(notebook.pageCount)")
                iconButton("chevron.right", "Next page", enabled: notebook.canGoToNextPage) {
                    notebook.goToNextPage()
                }
                divider
                addMenu
                divider
            }
            sizeMenu
            if allowsMultiplePages {
                iconButton("trash", "Delete page", enabled: notebook.canRemovePage) { confirmDelete = true }
                    .confirmationDialog("Delete page \(notebook.currentPageIndex + 1)?", isPresented: $confirmDelete) {
                        Button("Delete Page", role: .destructive) {
                            notebook.removePage(at: notebook.currentPageIndex)
                        }
                    } message: {
                        Text("Its ink is deleted too. This can't be undone.")
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .sheet(item: $customSizeTarget) { target in
            CustomPageSizeSheet(initial: target.initial) { size in apply(size, to: target.kind) }
        }
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
        } label: {
            menuLabel("plus", "Add page")
        } primaryAction: {
            notebook.addPage()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
            menuLabel("doc.badge.gearshape", "Page size")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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

    private var divider: some View {
        Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1, height: 24)
    }

    private func menuLabel(_ symbol: String, _ label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(width: 34, height: 36)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    private func iconButton(_ symbol: String, _ label: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
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
struct CustomPageSizeSheet: View {
    let initial: PageSize
    let onDone: (PageSize) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var unit = PageSize.Unit.localeDefault
    @State private var width: Double = 0
    @State private var height: Double = 0

    var body: some View {
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
                Text(unit.symbol).foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ v: CGFloat) -> String {
        Double(v).formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}
