import Combine
import SwiftUI
import UIKit

/// Another note that pages can be copied or moved to from the pages panel.
public struct PageDestination: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

/// Puts copies of pages into another note; true once they're there. The editor makes the copies
/// (`CanvasDocument.copy()`), and removes the originals afterwards for a move.
public typealias PageSender = @MainActor ([CanvasDocument], PageDestination) async -> Bool

// MARK: - Clipboard

/// Pages copied or cut in a pages panel, ready to paste into any note's panel. Held for the session only.
@MainActor
final class PageClipboard: ObservableObject {
    static let shared = PageClipboard()

    @Published private(set) var pages: [CanvasDocument] = []

    var isEmpty: Bool {
        pages.isEmpty
    }

    func copy(_ pages: [CanvasDocument]) {
        self.pages = pages.map { $0.copy() }
    }

    /// Pastes fresh copies after the page at `index`, so the clipboard can be pasted again.
    func paste(into notebook: InkNotebook, after index: Int) {
        for (offset, page) in pages.enumerated() {
            notebook.insert(page.copy(), at: min(index + 1 + offset, notebook.pageCount))
        }
    }
}

// MARK: - Pages panel

/// Figma **Nav/PagesPanel** (States 09 and 09b): a floating sheet on the trailing edge with every page as a
/// thumbnail in two columns. Tap a page to go to it; drag it to reorder; its "…" button (or a long press)
/// rotates, duplicates, moves to another note, copies, cuts, pastes, bookmarks and deletes it. The search
/// field filters to pages whose typed text matches, keeping their numbers. Select works on several pages at
/// once. Deleting shows an Undo toast instead of asking first.
struct PagesPanel: View {
    @ObservedObject var notebook: InkNotebook
    let destinations: [PageDestination]
    let sendPages: PageSender?

    @ObservedObject private var clipboard = PageClipboard.shared
    @State private var query = ""
    @State private var isSelecting = false
    @State private var selection = Set<CanvasDocument.ID>()
    @State private var lastDeleted: DeletedPages?
    @FocusState private var searchFocused: Bool
    @Environment(\.inkTheme) private var theme

    static let width: CGFloat = 264
    private static let thumbnail = CGSize(width: 108, height: 144)
    private static let padding: CGFloat = 16

    /// Pages taken out by Delete, with where they were, for Undo.
    private struct DeletedPages: Equatable {
        let id = UUID()
        let pages: [(index: Int, page: CanvasDocument)]

        static func == (lhs: DeletedPages, rhs: DeletedPages) -> Bool {
            lhs.id == rhs.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            let matches = matchingPages
            if matches.isEmpty {
                Text("No pages match")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.color(\.textSecondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid(matches)
            }
            footer
        }
        .frame(width: Self.width)
        .inkFloatingMaterial(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .bottom) {
            if let lastDeleted {
                undoToast(lastDeleted)
                    .padding(.bottom, 44 + 2 * InkSpacing.m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: notebook.pages.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
        .task(id: lastDeleted?.id) {
            guard lastDeleted != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                withAnimation { lastDeleted = nil }
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(isSelecting ? "\(selection.count) Selected" : "Pages")
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.color(\.textPrimary))
                Text(countText)
                    .font(theme.footnoteFont)
                    .foregroundStyle(theme.color(\.textSecondary))
            }
            Spacer(minLength: 0)
            Button(isSelecting ? "Done" : "Select") {
                withAnimation(.snappy) {
                    isSelecting.toggle()
                    selection.removeAll()
                }
            }
            .font(theme.bodyFont)
            .foregroundStyle(theme.color(\.accent))
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, InkSpacing.m)
        .padding(.bottom, InkSpacing.s)
    }

    private var countText: String {
        let total = notebook.pageCount
        let all = total == 1 ? String(localized: "1 page") : String(localized: "\(total) pages")
        guard !trimmedQuery.isEmpty else { return all }
        return String(localized: "\(matchingPages.count) of \(all)")
    }

    private var searchField: some View {
        HStack(spacing: InkSpacing.xs) {
            InkIconView(.search, size: 14)
                .foregroundStyle(theme.color(\.textSecondary))
            TextField("Search pages", text: $query)
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .tint(theme.color(\.accent))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    InkIconView(.close, size: 8)
                        .foregroundStyle(theme.color(\.surfaceRaised))
                        .frame(width: 16, height: 16)
                        .background(theme.color(\.textTertiary), in: Circle())
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.leading, InkSpacing.sm)
        .padding(.trailing, InkSpacing.xxs)
        .frame(height: 36)
        .background(theme.color(\.surfaceFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, Self.padding)
        .padding(.bottom, InkSpacing.m)
    }

    private func grid(_ pages: [(index: Int, page: CanvasDocument)]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.fixed(Self.thumbnail.width), spacing: Self.padding),
                                    GridItem(.fixed(Self.thumbnail.width))],
                          spacing: InkSpacing.m) {
                    ForEach(pages, id: \.page.id) { index, page in
                        cell(page, index: index)
                            .id(page.id)
                    }
                }
                .padding(.horizontal, Self.padding)
                // Room for the current page's ring, which the grid doesn't clip.
                .padding(.vertical, InkSpacing.xxs)
            }
            .scrollDismissesKeyboard(.immediately)
            .onAppear { proxy.scrollTo(notebook.currentPage.id, anchor: .center) }
            .onChange(of: notebook.currentPage.id) { _, id in
                withAnimation { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isSelecting {
            selectionBar
        } else {
            Button {
                withAnimation(.snappy) {
                    notebook.addPage()
                    notebook.goToPage(notebook.pageCount - 1)
                }
            } label: {
                HStack(spacing: InkSpacing.xs) {
                    InkIconView(.addPage, size: 16)
                    Text("Add Page").font(theme.bodyEmphasizedFont)
                }
                .foregroundStyle(theme.color(\.textPrimary))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(theme.color(\.surfaceFill), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(Self.padding)
        }
    }

    // MARK: Cell

    private func cell(_ page: CanvasDocument, index: Int) -> some View {
        let isCurrent = index == notebook.currentPageIndex
        let isSelected = selection.contains(page.id)
        return VStack(spacing: InkSpacing.xs) {
            PageThumbnailView(page: page, isCurrent: isCurrent, isSelected: isSelecting && isSelected,
                              isBookmarked: notebook.isBookmarked(page.id))
                .frame(width: Self.thumbnail.width, height: Self.thumbnail.height)
                .contentShape(Rectangle())
                .onTapGesture { tap(page, index: index) }
                .contextMenu { pageMenu(for: IndexSet(integer: index)) }
                .draggable(page.id.uuidString) {
                    PageThumbnailView(page: page, isCurrent: false, isSelected: false, isBookmarked: false)
                        .frame(width: Self.thumbnail.width, height: Self.thumbnail.height)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(UUID.init(uuidString:)),
                          let from = notebook.index(of: id), from != index else { return false }
                    withAnimation(.snappy) { notebook.movePage(from: from, to: index) }
                    return true
                }
            ZStack {
                number(index + 1, isCurrent: isCurrent)
                Menu {
                    pageMenu(for: IndexSet(integer: index))
                } label: {
                    InkIconView(.more, size: 14)
                        .foregroundStyle(theme.color(\.textSecondary))
                        .frame(width: 24, height: 24)
                        .background(theme.color(\.surfaceFill), in: Circle())
                        .frame(width: 44, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, -10)
                .accessibilityLabel("Page \(index + 1) Actions")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notebook.isBookmarked(page.id) ? "Page \(index + 1), bookmarked" : "Page \(index + 1)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func number(_ number: Int, isCurrent: Bool) -> some View {
        Text("\(number)")
            .font(theme.footnoteEmphasizedFont.monospacedDigit())
            .foregroundStyle(isCurrent ? theme.color(\.surfaceRaised) : theme.color(\.textSecondary))
            .padding(.horizontal, InkSpacing.xs)
            .frame(minWidth: 20, minHeight: 20)
            .background {
                if isCurrent {
                    Capsule().fill(theme.color(\.accent))
                }
            }
    }

    private func tap(_ page: CanvasDocument, index: Int) {
        if isSelecting {
            if selection.contains(page.id) {
                selection.remove(page.id)
            } else {
                selection.insert(page.id)
            }
        } else {
            searchFocused = false
            notebook.goToPage(index)
        }
    }

    // MARK: Page menu

    /// Rotate Left, Rotate Right | Duplicate, Move To…, Copy, Cut, Paste | Bookmark | Delete.
    @ViewBuilder
    private func pageMenu(for offsets: IndexSet) -> some View {
        Section {
            Button { notebook.rotatePages(at: offsets, clockwise: false) } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            Button { notebook.rotatePages(at: offsets) } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
        }
        Section {
            Button { notebook.duplicatePages(at: offsets) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if sendPages != nil {
                Menu {
                    destinationButtons { send(offsets, to: $0, move: true) }
                } label: {
                    Label("Move To…", systemImage: "folder")
                }
                .disabled(!notebook.canRemovePages(at: offsets))
                Menu {
                    destinationButtons { send(offsets, to: $0, move: false) }
                } label: {
                    Label("Copy To…", systemImage: "doc.on.doc")
                }
            }
            Button { clipboard.copy(pages(at: offsets)) } label: {
                Label("Copy", systemImage: "doc.on.clipboard")
            }
            Button {
                clipboard.copy(pages(at: offsets))
                delete(offsets)
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .disabled(!notebook.canRemovePages(at: offsets))
            if !clipboard.isEmpty, let last = offsets.last {
                Button { withAnimation(.snappy) { clipboard.paste(into: notebook, after: last) } } label: {
                    Label(clipboard.pages.count == 1 ? "Paste Page" : "Paste \(clipboard.pages.count) Pages",
                          systemImage: "doc.on.clipboard.fill")
                }
            }
        }
        if offsets.count == 1, let index = offsets.first, notebook.pages.indices.contains(index) {
            let id = notebook.pages[index].id
            Button { notebook.toggleBookmark(id) } label: {
                Label(notebook.isBookmarked(id) ? "Remove Bookmark" : "Bookmark",
                      systemImage: notebook.isBookmarked(id) ? "bookmark.slash" : "bookmark")
            }
        }
        Section {
            Button(role: .destructive) { delete(offsets) } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!notebook.canRemovePages(at: offsets))
        }
    }

    @ViewBuilder
    private func destinationButtons(_ choose: @escaping (PageDestination) -> Void) -> some View {
        if destinations.isEmpty {
            Text("No Other Notes")
        }
        ForEach(destinations) { destination in
            Button(destination.title.isEmpty ? "Untitled" : destination.title) { choose(destination) }
        }
    }

    private var selectionBar: some View {
        let offsets = selectedOffsets
        return HStack(spacing: InkSpacing.xxxs) {
            Button { notebook.duplicatePages(at: offsets) } label: { Image(systemName: "plus.square.on.square") }
                .accessibilityLabel("Duplicate")
            Button { notebook.rotatePages(at: offsets) } label: { Image(systemName: "rotate.right") }
                .accessibilityLabel("Rotate")
            if sendPages != nil {
                Menu {
                    Menu("Move To…") { destinationButtons { send(offsets, to: $0, move: true) } }
                        .disabled(!notebook.canRemovePages(at: offsets))
                    Menu("Copy To…") { destinationButtons { send(offsets, to: $0, move: false) } }
                } label: {
                    Image(systemName: "arrow.right.doc.on.clipboard")
                }
                .accessibilityLabel("Copy or Move")
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                delete(offsets)
                selection.removeAll()
            } label: { InkIconView(.delete) }
                .disabled(!notebook.canRemovePages(at: offsets))
                .accessibilityLabel("Delete")
        }
        .buttonStyle(.inkIcon)
        .disabled(offsets.isEmpty)
        .padding(.horizontal, InkSpacing.s)
        .padding(.vertical, InkSpacing.s)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color(\.separator)).frame(height: 0.5)
        }
    }

    private func undoToast(_ deleted: DeletedPages) -> some View {
        HStack(spacing: InkSpacing.m) {
            Text(deleted.pages.count == 1 ? "Page deleted" : "\(deleted.pages.count) pages deleted")
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textPrimary))
            Button("Undo") { undoDelete(deleted) }
                .font(theme.bodyEmphasizedFont)
                .foregroundStyle(theme.color(\.accent))
        }
        .padding(.horizontal, InkSpacing.l)
        .frame(height: 40)
        .background(theme.color(\.surfaceRaised), in: Capsule())
        .shadow(color: theme.color(\.shadow).opacity(0.14), radius: 10, y: 6)
    }

    // MARK: Actions

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pages whose typed text contains the search, with their original indices.
    private var matchingPages: [(index: Int, page: CanvasDocument)] {
        let all = notebook.pages.enumerated().map { (index: $0.offset, page: $0.element) }
        let search = trimmedQuery
        guard !search.isEmpty else { return all }
        return all.filter { $0.page.text.localizedCaseInsensitiveContains(search) }
    }

    private var selectedOffsets: IndexSet {
        IndexSet(selection.compactMap { notebook.index(of: $0) })
    }

    private func pages(at offsets: IndexSet) -> [CanvasDocument] {
        offsets.compactMap { notebook.pages.indices.contains($0) ? notebook.pages[$0] : nil }
    }

    /// Deletes the pages, keeping them for the Undo toast.
    private func delete(_ offsets: IndexSet) {
        guard notebook.canRemovePages(at: offsets) else { return }
        let removed = offsets.compactMap { index in
            notebook.pages.indices.contains(index) ? (index: index, page: notebook.pages[index]) : nil
        }
        withAnimation(.snappy) {
            notebook.removePages(at: offsets)
            lastDeleted = DeletedPages(pages: removed)
        }
    }

    /// Puts deleted pages back where they were, lowest index first so later indices still line up.
    private func undoDelete(_ deleted: DeletedPages) {
        withAnimation(.snappy) {
            for (index, page) in deleted.pages.sorted(by: { $0.index < $1.index }) {
                notebook.insert(page, at: min(index, notebook.pageCount))
            }
            lastDeleted = nil
        }
    }

    /// Copies the pages into `destination`, then for a move takes them out of this notebook.
    private func send(_ offsets: IndexSet, to destination: PageDestination, move: Bool) {
        guard let sendPages else { return }
        let originals = pages(at: offsets)
        let copies = originals.map { $0.copy() }
        Task { @MainActor in
            guard await sendPages(copies, destination), move else { return }
            // The pages may have moved while copying; remove them by identity.
            let remaining = IndexSet(originals.compactMap { notebook.index(of: $0.id) })
            notebook.removePages(at: remaining)
            selection.removeAll()
        }
    }
}

/// Figma **Nav/PageThumbnail**: a page fitted into a 108 × 144 slot. The current page gets a 3 pt accent
/// ring; selected pages a checkmark.
private struct PageThumbnailView: View {
    let page: CanvasDocument
    let isCurrent: Bool
    let isSelected: Bool
    let isBookmarked: Bool

    @StateObject private var thumbnail = PageThumbnail()
    @Environment(\.inkTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = thumbnail.image {
                    Image(uiImage: image).resizable()
                } else {
                    theme.color(\.paper)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.color(\.border), lineWidth: 0.5))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.color(\.accent), lineWidth: 3)
                        .padding(-3)
                }
            }
            .shadow(color: theme.color(\.shadow).opacity(0.10), radius: 2, y: 1)
            if isBookmarked {
                InkIconView(.bookmark, size: 14)
                    .foregroundStyle(theme.color(\.accent))
                    .padding(InkSpacing.xxs)
                    .accessibilityHidden(true)
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.color(\.textSelected), theme.color(\.accent))
                    .padding(InkSpacing.xxs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .aspectRatio(page.pageSize.width / page.pageSize.height, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { thumbnail.show(page, palette: theme.palette(for: page.template.paper)) }
        .onDisappear { thumbnail.stop() }
        .onChange(of: page.template) { _, template in
            thumbnail.show(page, palette: theme.palette(for: template.paper))
        }
        .onChange(of: page.pageSize) { _, _ in
            thumbnail.show(page, palette: theme.palette(for: page.template.paper))
        }
    }
}

// MARK: - Thumbnails

/// A page's thumbnail, rendered in the background and redrawn shortly after the page changes.
@MainActor
final class PageThumbnail: ObservableObject {
    @Published private(set) var image: UIImage?
    private var page: CanvasDocument?
    private var palette: PaperPalette?
    private var renderedKey: PageThumbnailCache.Key?
    private var pendingRedraw: DispatchWorkItem?

    /// Thumbnails are this many pixels wide.
    static let pixelWidth = 320

    func show(_ page: CanvasDocument, palette: PaperPalette) {
        if self.page !== page {
            self.page?.stopObservingChanges(self)
            self.page = page
            page.observeChanges(self) { [weak self] in self?.pageDidChange() }
        }
        self.palette = palette
        render()
    }

    func stop() {
        page?.stopObservingChanges(self)
        page = nil
        pendingRedraw?.cancel()
    }

    /// Waits for a pause in the writing, so a page being written on isn't redrawn on every stroke.
    private func pageDidChange() {
        pendingRedraw?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render() }
        pendingRedraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func render() {
        guard let page, let palette else { return }
        let key = PageThumbnailCache.Key(page: page)
        guard key != renderedKey else { return }
        if let cached = PageThumbnailCache.shared.image(for: key) {
            renderedKey = key
            image = cached
            return
        }
        let snapshot = page.snapshot()
        PageThumbnailCache.shared.render(snapshot, key: key, palette: palette) { [weak self] rendered in
            guard let self, let rendered, self.page?.id == key.pageID else { return }
            renderedKey = key
            image = rendered
        }
    }
}

/// Recently drawn page thumbnails, shared by every pages panel, so scrolling back up doesn't draw them again.
/// Renders run off the main thread as background jobs on the render scheduler, at most two at once.
@MainActor
final class PageThumbnailCache {
    static let shared = PageThumbnailCache()

    /// What a thumbnail shows: a page at one revision, objects revision, size and template.
    struct Key: Hashable {
        let pageID: UUID
        let revision: Int
        let objectsRevision: Int
        let size: PageSize
        let template: PageTemplate

        @MainActor init(page: CanvasDocument) {
            pageID = page.id
            revision = page.revision
            objectsRevision = page.objectsRevision
            size = page.pageSize
            template = page.template
        }
    }

    private let images = NSCache<KeyBox, UIImage>()

    init() {
        images.countLimit = 150
    }

    func image(for key: Key) -> UIImage? {
        images.object(forKey: KeyBox(key))
    }

    func render(_ snapshot: PageSnapshot, key: Key, palette: PaperPalette,
                completion: @escaping @MainActor (UIImage?) -> Void) {
        let width = PageThumbnail.pixelWidth
        RenderScheduler.shared.submit(RenderJob(priority: .background, work: { _ in
            PageRenderer.image(of: snapshot, pixelWidth: width) { _ in palette }.map { UIImage(cgImage: $0) }
        }, publish: { [weak self] (image: UIImage?) in
            if let image {
                self?.images.setObject(image, forKey: KeyBox(key))
            }
            completion(image)
        }))
    }

    private final class KeyBox: NSObject {
        let key: Key
        init(_ key: Key) {
            self.key = key
        }

        override var hash: Int {
            key.hashValue
        }

        override func isEqual(_ object: Any?) -> Bool {
            (object as? KeyBox)?.key == key
        }
    }
}
