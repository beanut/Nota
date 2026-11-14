import SwiftUI

/// The pen tray: the user's saved pens (brush, colour and width) in their order. Tap a pen to write with
/// it; Save Current Pen adds the one in use. Edit reorders and deletes; each pen's menu renames it,
/// updates it to the current pen, or moves it.
struct PenTrayView: View {
    @ObservedObject var controller: CanvasController
    @State private var editMode: EditMode = .inactive
    @State private var renaming: SavedPen?
    @State private var draftName = ""
    @Environment(\.inkTheme) private var theme

    private var pens: [SavedPen] {
        controller.penTray.tray.pens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.m) {
            HStack {
                Text("Pens")
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.color(\.textPrimary))
                Spacer()
                if !pens.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .font(theme.bodyEmphasizedFont)
                    .foregroundStyle(theme.color(\.textSelected))
                }
            }
            .padding(.top, InkSpacing.s)
            .padding(.horizontal, InkSpacing.l)

            if pens.isEmpty {
                Text("Save the pen you're writing with to come back to its brush, color and width in one tap.")
                    .font(theme.footnoteFont)
                    .foregroundStyle(theme.color(\.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, InkSpacing.l)
            } else {
                list
            }

            Button {
                controller.saveCurrentPen()
            } label: {
                HStack(spacing: InkSpacing.xs) {
                    InkIconView(.addPage, size: 16)
                    Text("Save Current Pen")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkSecondaryButtonStyle())
            .disabled(controller.tool.penKind == nil)
            .padding(.horizontal, InkSpacing.l)
            if controller.tool.penKind == nil {
                Text("Choose a pen, pencil or highlighter to save it.")
                    .font(theme.footnoteFont)
                    .foregroundStyle(theme.color(\.textSecondary))
                    .padding(.horizontal, InkSpacing.l)
            }
        }
        .frame(width: 360)
        .inkPopoverContent()
        .alert("Rename Pen", isPresented: Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renaming?.id {
                    controller.penTray.update { $0.renamePen(id: id, to: draftName) }
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(pens) { pen in
                PenRow(pen: pen, isCurrent: controller.isCurrent(pen)) {
                    controller.use(pen)
                }
                .contextMenu { menu(for: pen) }
                .listRowInsets(EdgeInsets(top: InkSpacing.xxxs, leading: InkSpacing.s, bottom: InkSpacing.xxxs,
                                          trailing: InkSpacing.s))
                .listRowBackground(theme.color(\.surfaceRaised))
                .listRowSeparator(.hidden)
            }
            .onMove { source, destination in
                controller.penTray.update { $0.movePens(fromOffsets: source, toOffset: destination) }
            }
            .onDelete { offsets in
                let ids = offsets.map { pens[$0].id }
                controller.penTray.update { tray in ids.forEach { tray.removePen(id: $0) } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .frame(height: min(CGFloat(pens.count) * 52, 364))
    }

    @ViewBuilder
    private func menu(for pen: SavedPen) -> some View {
        Button {
            draftName = pen.name
            renaming = pen
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button { controller.updatePenToCurrent(pen) } label: {
            Label("Update to Current Pen", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(controller.tool.penKind == nil || controller.isCurrent(pen))
        Button { controller.penTray.update { $0.movePen(id: pen.id, by: -1) } } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(pens.first?.id == pen.id)
        Button { controller.penTray.update { $0.movePen(id: pen.id, by: 1) } } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(pens.last?.id == pen.id)
        Divider()
        Button(role: .destructive) { controller.penTray.update { $0.removePen(id: pen.id) } } label: {
            Label("Delete Pen", systemImage: "trash")
        }
    }
}

/// A saved pen: its sample stroke in its colour, its name, and its tool and width.
private struct PenRow: View {
    let pen: SavedPen
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.inkTheme) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: InkSpacing.m) {
                preview
                    .frame(width: InkMetrics.penPreview.width, height: InkMetrics.penPreview.height)
                VStack(alignment: .leading, spacing: InkSpacing.xxxs) {
                    Text(pen.name)
                        .font(isCurrent ? theme.bodyEmphasizedFont : theme.bodyFont)
                        .foregroundStyle(theme.color(isCurrent ? \.textSelected : \.textPrimary))
                        .lineLimit(1)
                    Text(detail)
                        .font(theme.footnoteFont)
                        .foregroundStyle(theme.color(\.textSecondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                InkIconView(pen.kind.tool.icon, size: 16)
                    .foregroundStyle(theme.color(\.textSecondary))
            }
            .padding(.horizontal, InkSpacing.s)
            .frame(minHeight: 48)
            .background(isCurrent ? theme.color(\.surfaceSelected) : .clear,
                        in: RoundedRectangle(cornerRadius: InkMetrics.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pen.name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var detail: String {
        let width = pen.width.formatted(.number.precision(.fractionLength(1))) + " pt"
        // The brush's name, unless the pen is named after it; the preview shows the colour.
        return pen.name == pen.brush.name ? width : "\(pen.brush.name) · \(width)"
    }

    @ViewBuilder
    private var preview: some View {
        let brush = pen.brush.sized(CGFloat(pen.width), minimumRatio: pen.brush.maxWidth > 0
            ? pen.brush.size.lowerBound / pen.brush.maxWidth : 1)
        if let image = BrushPreview.image(of: brush, color: pen.color.rgba, scale: displayScale,
                                          size: InkMetrics.penPreview) {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }
}
