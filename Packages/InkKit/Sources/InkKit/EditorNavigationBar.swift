import SwiftUI
import UIKit

// MARK: - Host API

/// A note the title menu offers to switch to.
public struct RecentNote: Identifiable {
    public let id: UUID
    public let title: String
    /// "Linear Algebra · Today": where it's filed and when it was last edited.
    public let subtitle: String
    /// Its first page, if the host has one to hand.
    public let thumbnail: UIImage?

    public init(id: UUID, title: String, subtitle: String, thumbnail: UIImage? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
    }
}

/// What the editor's navigation row does beyond the note itself: its leading button, the recent notes in
/// the title menu, and the host's own items in the More menu.
public struct EditorNavigation {
    /// The leading button: Back (a chevron) out of a navigation stack, or Close (an ✕) for a note in a window
    /// or one side of a split.
    public enum Leading {
        case back, close
    }

    public var leading: Leading?
    public var leadingAction: () -> Void
    /// The note being edited, checked in the title menu.
    public var currentNoteID: UUID?
    /// The most recently edited notes, newest first.
    public var recentNotes: [RecentNote]
    /// Switches to another note in this one's place, without going back to the library.
    public var openNote: (UUID) -> Void
    /// The host's items at the top of the More menu (windows, split view).
    public var moreMenuItems: AnyView?

    public init(leading: Leading?, leadingAction: @escaping () -> Void = {}, currentNoteID: UUID? = nil,
                recentNotes: [RecentNote] = [], openNote: @escaping (UUID) -> Void = { _ in },
                moreMenuItems: AnyView? = nil) {
        self.leading = leading
        self.leadingAction = leadingAction
        self.currentNoteID = currentNoteID
        self.recentNotes = recentNotes
        self.openNote = openNote
        self.moreMenuItems = moreMenuItems
    }
}

// MARK: - Navigation row

/// The editor's transparent navigation row (Figma **Nav**): a circular back button, the note's title in a
/// capsule that opens the title menu (Rename and recent notes), and the trailing actions — Search, AI,
/// Share, Pages and More — in a capsule of their own. All three float over the page in the tool picker's
/// material.
struct EditorNavigationBar: View {
    @ObservedObject var controller: CanvasController
    @ObservedObject var notebook: InkNotebook
    let title: Binding<String>?
    let navigation: EditorNavigation?
    let showsPageControls: Bool
    @Binding var showsPages: Bool
    @Binding var showsTitleMenu: Bool
    /// Back after following a link: "Page 3", or the note the link came from.
    let linkBackTitle: String?
    let linkBack: () -> Void

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool
    @Environment(\.inkTheme) private var theme

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: InkSpacing.s) {
            if let navigation, let leading = navigation.leading {
                Button(action: navigation.leadingAction) {
                    InkIconView(leading == .back ? .back : .close, size: leading == .back ? 20 : 18)
                        .frame(width: Self.height, height: Self.height)
                        .contentShape(Circle())
                }
                .buttonStyle(NavGlyphButtonStyle())
                .inkFloatingMaterial(in: Circle())
                .accessibilityLabel(leading == .back ? "Back" : "Close")
            }
            if title != nil {
                titleCapsule
            }
            if let linkBackTitle {
                LinkBackButton(title: linkBackTitle, action: linkBack)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: InkSpacing.s)
            trailingActions
        }
        .frame(height: Self.height)
    }

    // MARK: Title

    @ViewBuilder
    private var titleCapsule: some View {
        if isRenaming {
            HStack(spacing: 10) {
                TextField("Title", text: $draftTitle)
                    .font(.headline)
                    .foregroundStyle(theme.color(\.textPrimary))
                    .tint(theme.color(\.accent))
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { finishRenaming(save: true) }
                    .onKeyPress(.escape) {
                        finishRenaming(save: false)
                        return .handled
                    }
                    .fixedSize()
                    .frame(minWidth: 80, alignment: .leading)
                Button { draftTitle = "" } label: {
                    InkIconView(.close, size: 10)
                        .foregroundStyle(theme.color(\.surfaceRaised))
                        .frame(width: 18, height: 18)
                        .background(theme.color(\.textTertiary), in: Circle())
                        .frame(width: 30, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Title")
            }
            .padding(.leading, InkSpacing.l)
            .padding(.trailing, InkSpacing.xxs)
            .frame(height: Self.height)
            .inkFloatingMaterial()
            .onChange(of: titleFocused) { _, focused in
                if !focused, isRenaming {
                    finishRenaming(save: true) // tapping outside saves
                }
            }
        } else {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsTitleMenu.toggle() }
            } label: {
                HStack(spacing: InkSpacing.xs) {
                    Text(displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    InkIconView(.disclosure, size: 16)
                }
                .foregroundStyle(theme.color(\.textPrimary))
                .padding(.leading, InkSpacing.l)
                .padding(.trailing, 14)
                .frame(height: Self.height)
                .contentShape(Capsule())
            }
            .buttonStyle(NavGlyphButtonStyle())
            .inkFloatingMaterial()
            .accessibilityLabel(displayTitle)
            .accessibilityHint("Shows recent notes and Rename.")
            .overlay(alignment: .topLeading) {
                if showsTitleMenu {
                    TitleMenu(navigation: navigation, rename: startRenaming, dismiss: closeTitleMenu)
                        .offset(y: Self.height + InkSpacing.s)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
        }
    }

    private var displayTitle: String {
        let text = title?.wrappedValue ?? ""
        return text.isEmpty ? String(localized: "Untitled") : text
    }

    private func closeTitleMenu() {
        withAnimation(.snappy(duration: 0.2)) { showsTitleMenu = false }
    }

    private func startRenaming() {
        closeTitleMenu()
        draftTitle = title?.wrappedValue ?? ""
        isRenaming = true
        titleFocused = true
        // The whole title starts selected, so typing replaces it.
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
    }

    /// Return or tapping outside saves; Escape reverts. An empty title reverts too.
    private func finishRenaming(save: Bool) {
        guard isRenaming else { return }
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if save, !trimmed.isEmpty {
            title?.wrappedValue = trimmed
        }
        isRenaming = false
        titleFocused = false
    }

    // MARK: Trailing actions

    private var trailingActions: some View {
        HStack(spacing: 0) {
            // Search, AI and Share aren't designed yet: they're here so the row has its final shape.
            navButton(.search, label: "Search") {}
            navButton(.ai, label: "Assistant") {}
            navButton(.share, label: "Share") {}
            if showsPageControls {
                Button {
                    withAnimation(.snappy) { showsPages.toggle() }
                } label: {
                    InkIconView(.pages, size: 24)
                        .frame(width: 36, height: 36)
                        .background {
                            if showsPages {
                                Circle().fill(theme.color(\.selectionPill))
                                    .shadow(color: theme.color(\.shadow).opacity(0.12), radius: 3, y: 2)
                            }
                        }
                        .frame(width: Self.height, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NavGlyphButtonStyle())
                .accessibilityLabel("Pages")
                .accessibilityAddTraits(showsPages ? .isSelected : [])
            }
            EditorMoreMenu(controller: controller, notebook: notebook, showsPageControls: showsPageControls,
                           hostItems: navigation?.moreMenuItems)
        }
        .padding(.horizontal, InkSpacing.xxs)
        .inkFloatingMaterial()
    }

    private func navButton(_ icon: InkIcon, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InkIconView(icon, size: 24)
                .frame(width: Self.height, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(NavGlyphButtonStyle())
        .accessibilityLabel(label)
    }
}

/// A glyph in the navigation row: label colour, dimmed while pressed.
private struct NavGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NavGlyphButtonBody(configuration: configuration)
    }
}

private struct NavGlyphButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.inkTheme) private var theme

    var body: some View {
        configuration.label
            .foregroundStyle(theme.color(\.textPrimary))
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// MARK: - Title menu

/// Figma State 08: Rename, then the five most recently edited notes with the open one checked. Tapping a
/// note switches to it in place.
private struct TitleMenu: View {
    let navigation: EditorNavigation?
    let rename: () -> Void
    let dismiss: () -> Void
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: rename) {
                HStack(spacing: InkSpacing.m) {
                    Image(systemName: "pencil")
                        .font(.body)
                        .frame(width: 22)
                    Text("Rename")
                        .font(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.color(\.textPrimary))
                .padding(.horizontal, InkSpacing.m)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let recents = navigation?.recentNotes ?? []
            if !recents.isEmpty {
                Rectangle()
                    .fill(theme.color(\.separator))
                    .frame(height: 0.5)
                    .padding(.vertical, InkSpacing.xxs)
                Text("Recent Notes")
                    .font(theme.footnoteEmphasizedFont)
                    .foregroundStyle(theme.color(\.textSecondary))
                    .padding(.horizontal, InkSpacing.m)
                    .padding(.vertical, InkSpacing.xs)
                ForEach(recents) { note in
                    row(note)
                }
            }
        }
        .padding(InkSpacing.s)
        .frame(width: 320)
        .inkFloatingMaterial(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func row(_ note: RecentNote) -> some View {
        let isCurrent = note.id == navigation?.currentNoteID
        return Button {
            dismiss()
            if !isCurrent {
                navigation?.openNote(note.id)
            }
        } label: {
            HStack(spacing: InkSpacing.m) {
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                Group {
                    if let image = note.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        theme.color(\.paper)
                    }
                }
                .frame(width: 36, height: 48)
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.color(\.border), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? String(localized: "Untitled") : note.title)
                        .font(.body)
                        .foregroundStyle(theme.color(\.textPrimary))
                        .lineLimit(1)
                    Text(note.subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.color(\.textSecondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    InkIconView(.check, size: 16)
                        .foregroundStyle(theme.color(\.accent))
                }
            }
            .padding(.horizontal, InkSpacing.m)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(note.title) + Text(", ") + Text(note.subtitle))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - More menu

/// Everything the design has no place for yet: the host's window items, the page's setup, the outline,
/// saved pens and brush options, view and Pencil settings, debugging, and Clear Page.
private struct EditorMoreMenu: View {
    @ObservedObject var controller: CanvasController
    @ObservedObject var notebook: InkNotebook
    let showsPageControls: Bool
    let hostItems: AnyView?

    private enum Panel: String, Identifiable {
        case page, outline, pens, toolOptions, pressure, pencil

        var id: String {
            rawValue
        }
    }

    @State private var panel: Panel?
    @State private var confirmClear = false
    @Environment(\.inkTheme) private var theme

    var body: some View {
        Menu {
            if let hostItems {
                hostItems
                Divider()
            }
            Section {
                Button { panel = .page } label: {
                    Label(showsPageControls ? "Page \(notebook.currentPageIndex + 1) of \(notebook.pageCount)…" : "Page…",
                          systemImage: "doc")
                }
                if showsPageControls {
                    Button { panel = .outline } label: { Label("Outline…", systemImage: "list.bullet.indent") }
                }
            }
            Section {
                Button { panel = .pens } label: { Label("Saved Pens…", systemImage: "tray.full") }
                Button { panel = .toolOptions } label: { Label("Tool Options…", systemImage: "slider.horizontal.3") }
            }
            Section {
                FitPageButton(readout: controller.zoomReadout) { controller.resetZoom() }
                if controller.pageLayout == .paged || !controller.allowsContinuousLayout {
                    Toggle(isOn: $controller.zoomWindowVisible) {
                        Label("Zoom Window", systemImage: "rectangle.and.text.magnifyingglass")
                    }
                }
                if controller.allowsContinuousLayout {
                    Picker(selection: $controller.pageLayout) {
                        ForEach(PageLayoutMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode == .paged ? "arrow.left.and.right" : "arrow.up.and.down")
                                .tag(mode)
                        }
                    } label: {
                        Label("Scroll Direction", systemImage: "arrow.up.and.down.text.horizontal")
                    }
                    .pickerStyle(.menu)
                }
            }
            Section {
                Button { panel = .pressure } label: { Label("Pressure & Tilt…", systemImage: "hand.draw") }
                Button { panel = .pencil } label: { Label("Apple Pencil…", systemImage: "applepencil") }
                Toggle(isOn: $controller.hudVisible) {
                    Label("Debug HUD", systemImage: "gauge.with.dots.needle.67percent")
                }
                Toggle(isOn: Binding(get: { controller.isRecordingInput }, set: { controller.setRecordingInput($0) })) {
                    Label("Record Pencil Input", systemImage: "record.circle")
                }
                if let url = controller.lastRecordingURL, !controller.isRecordingInput {
                    ShareLink(item: url) {
                        Label("Share Pencil Recording…", systemImage: "square.and.arrow.up")
                    }
                }
                Button { controller.insertPlaceholderObject() } label: {
                    Label("Add Test Object", systemImage: "square.on.square.dashed")
                }
            }
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear Page", systemImage: "trash")
            }
            .disabled(!controller.canUndo && !controller.canRedo)
        } label: {
            InkIconView(.more, size: 24)
                .foregroundStyle(theme.color(\.textPrimary))
                .frame(width: EditorNavigationBar.height, height: EditorNavigationBar.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .popover(item: $panel, arrowEdge: .top) { panel in
            switch panel {
            case .page:
                PageBar(notebook: notebook, allowsMultiplePages: showsPageControls)
                    .padding(InkSpacing.m)
                    .presentationCompactAdaptation(.popover)
            case .outline:
                OutlinePanel(notebook: notebook)
                    .frame(width: 300, height: 420)
                    .presentationCompactAdaptation(.popover)
            case .pens:
                PenTrayView(controller: controller)
            case .toolOptions:
                ToolOptionsView(controller: controller, tool: controller.tool)
            case .pressure:
                CanvasSettingsView(controller: controller)
            case .pencil:
                PencilSettingsView(controller: controller)
            }
        }
        .confirmationDialog("Clear the page?", isPresented: $confirmClear) {
            Button("Clear Page", role: .destructive) { controller.clear() }
        } message: {
            Text("You can undo this.")
        }
    }
}

/// The More menu's Fit Page item, showing the zoom. It alone watches the zoom, so a pinch updates this item
/// and not the whole More menu.
private struct FitPageButton: View {
    @ObservedObject var readout: ZoomReadout
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Fit Page · \(Int((readout.zoom * 100).rounded()))%", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }
}
