import Combine
import SwiftUI
import UIKit

/// Another note that pages can be copied or moved to from the page sidebar.
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

/// The page sidebar: a thumbnail of every page, in order. Tap a page to go to it, or drag it to a new
/// place. Select shows checkmarks for working on several pages at once: duplicate, rotate, delete, and
/// copy or move to another note. Each page's context menu has the same actions for that page.
struct PageSidebar: View {
    @ObservedObject var notebook: InkNotebook
    let destinations: [PageDestination]
    let sendPages: PageSender?
    let onClose: () -> Void

    @State private var isSelecting = false
    @State private var selection = Set<CanvasDocument.ID>()
    @State private var pendingDelete: IndexSet?
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                        row(page, index: index)
                            .id(page.id)
                    }
                    .onMove { notebook.movePages(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                .onAppear { proxy.scrollTo(notebook.currentPage.id, anchor: .center) }
                .onChange(of: notebook.currentPage.id) { _, id in
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            if isSelecting {
                selectionBar
            }
        }
        .frame(width: InkMetrics.pageSidebarWidth)
        .background(theme.color(\.surfaceRaised))
        .clipShape(RoundedRectangle(cornerRadius: InkMetrics.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: InkMetrics.panelRadius, style: .continuous)
            .strokeBorder(theme.color(\.border), lineWidth: 0.5))
        .shadow(color: theme.color(\.shadow).opacity(0.10), radius: 6, y: 8)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                              set: {
                                                                  if !$0 {
                                                                      pendingDelete = nil
                                                                  }
                                                              })) {
            Button(deleteTitle, role: .destructive) {
                if let pendingDelete {
                    delete(pendingDelete)
                }
            }
        } message: {
            Text("Their ink is deleted too. This can't be undone.")
        }
        .onChange(of: notebook.pages.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: InkSpacing.xxs) {
            Text(isSelecting ? "\(selection.count) Selected" : "Pages")
                .font(theme.headlineFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button(isSelecting ? "Done" : "Select") {
                withAnimation {
                    isSelecting.toggle()
                    selection.removeAll()
                }
            }
            .font(theme.bodyEmphasizedFont)
            .foregroundStyle(theme.color(\.accent))
            Button(action: onClose) { InkIconView(.close) }
                .buttonStyle(.inkIcon)
                .accessibilityLabel("Close Pages")
        }
        .padding(.leading, InkSpacing.m)
        .padding(.trailing, InkSpacing.xxs)
        .padding(.vertical, InkSpacing.xxs)
    }

    private func row(_ page: CanvasDocument, index: Int) -> some View {
        let isCurrent = index == notebook.currentPageIndex
        let isSelected = selection.contains(page.id)
        return PageThumbnailRow(page: page, number: index + 1, isCurrent: isCurrent,
                                isSelected: isSelecting && isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    if isSelected {
                        selection.remove(page.id)
                    } else {
                        selection.insert(page.id)
                    }
                } else {
                    notebook.goToPage(index)
                }
            }
            .contextMenu { actions(for: IndexSet(integer: index)) }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: InkSpacing.xs, leading: InkSpacing.m,
                                      bottom: InkSpacing.xs, trailing: InkSpacing.m))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Page \(index + 1)")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
                    sendMenu(for: offsets)
                } label: {
                    Image(systemName: "arrow.right.doc.on.clipboard")
                }
                .accessibilityLabel("Copy or Move")
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { pendingDelete = offsets } label: { InkIconView(.delete) }
                .disabled(!notebook.canRemovePages(at: offsets))
                .accessibilityLabel("Delete")
        }
        .buttonStyle(.inkIcon)
        .disabled(offsets.isEmpty)
        .padding(.horizontal, InkSpacing.xs)
        .padding(.vertical, InkSpacing.xxs)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color(\.separator)).frame(height: 0.5)
        }
    }

    /// The actions for the pages at `offsets`, for a page's context menu.
    @ViewBuilder
    private func actions(for offsets: IndexSet) -> some View {
        Button { notebook.duplicatePages(at: offsets) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button { notebook.rotatePages(at: offsets) } label: {
            Label("Rotate Right", systemImage: "rotate.right")
        }
        Button { notebook.rotatePages(at: offsets, clockwise: false) } label: {
            Label("Rotate Left", systemImage: "rotate.left")
        }
        if sendPages != nil {
            sendMenu(for: offsets)
        }
        Divider()
        Button(role: .destructive) { pendingDelete = offsets } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!notebook.canRemovePages(at: offsets))
    }

    @ViewBuilder
    private func sendMenu(for offsets: IndexSet) -> some View {
        Menu {
            destinationButtons { send(offsets, to: $0, move: false) }
        } label: {
            Label("Copy to Note", systemImage: "doc.on.doc")
        }
        Menu {
            destinationButtons { send(offsets, to: $0, move: true) }
        } label: {
            Label("Move to Note", systemImage: "arrow.right.doc.on.clipboard")
        }
        .disabled(!notebook.canRemovePages(at: offsets))
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

    // MARK: Actions

    private var selectedOffsets: IndexSet {
        IndexSet(selection.compactMap { notebook.index(of: $0) })
    }

    private var deleteTitle: String {
        let count = pendingDelete?.count ?? 0
        return count == 1 ? "Delete Page" : "Delete \(count) Pages"
    }

    private func delete(_ offsets: IndexSet) {
        notebook.removePages(at: offsets)
        pendingDelete = nil
    }

    /// Copies the pages into `destination`, then for a move takes them out of this notebook.
    private func send(_ offsets: IndexSet, to destination: PageDestination, move: Bool) {
        guard let sendPages else { return }
        let originals = offsets.compactMap { notebook.pages.indices.contains($0) ? notebook.pages[$0] : nil }
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

// MARK: - Thumbnails

/// One page in the sidebar: its thumbnail and number. The current page is outlined in the accent colour.
private struct PageThumbnailRow: View {
    let page: CanvasDocument
    let number: Int
    let isCurrent: Bool
    let isSelected: Bool

    @StateObject private var thumbnail = PageThumbnail()
    @Environment(\.inkTheme) private var theme

    var body: some View {
        VStack(spacing: InkSpacing.xxs) {
            let shape = RoundedRectangle(cornerRadius: InkMetrics.paperRadius, style: .continuous)
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = thumbnail.image {
                        Image(uiImage: image).resizable()
                    } else {
                        theme.color(\.paper)
                    }
                }
                .aspectRatio(page.pageSize.width / page.pageSize.height, contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(isCurrent ? theme.color(\.accent) : theme.color(\.border),
                                            lineWidth: isCurrent ? 2 : 0.5))
                .shadow(color: theme.color(\.shadow).opacity(0.10), radius: 2, y: 1)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(theme.color(\.textSelected), theme.color(\.accent))
                        .padding(InkSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity)
            Text("\(number)")
                .font(theme.footnoteFont.monospacedDigit())
                .foregroundStyle(isCurrent ? theme.color(\.accent) : theme.color(\.textSecondary))
        }
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

/// A page's thumbnail, rendered in the background and redrawn shortly after the page changes.
@MainActor
private final class PageThumbnail: ObservableObject {
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

/// Recently drawn page thumbnails, shared by every sidebar, so scrolling back up doesn't draw them again.
/// Renders run two at a time off the main thread.
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
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "InkKit.pageThumbnails"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    init() {
        images.countLimit = 150
    }

    func image(for key: Key) -> UIImage? {
        images.object(forKey: KeyBox(key))
    }

    func render(_ snapshot: PageSnapshot, key: Key, palette: PaperPalette,
                completion: @escaping @MainActor (UIImage?) -> Void) {
        let width = PageThumbnail.pixelWidth
        queue.addOperation { [weak self] in
            let cgImage = PageRenderer.image(of: snapshot, pixelWidth: width) { _ in palette }
            let image = cgImage.map { UIImage(cgImage: $0) }
            Task { @MainActor in
                if let image {
                    self?.images.setObject(image, forKey: KeyBox(key))
                }
                completion(image)
            }
        }
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
