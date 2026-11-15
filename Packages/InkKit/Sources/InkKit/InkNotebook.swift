import Combine
import Foundation

/// An ordered stack of pages, each a `CanvasDocument` with its own paper size, template and undo history.
///
/// A notebook always has at least one page, and `currentPageIndex` is always a valid index.
///
/// ```swift
/// let notebook = InkNotebook()                    // one Letter page
/// notebook.addPage()                              // appends a page sized like the current one
/// notebook.addPage(size: .a4.landscape)           // or any preset / custom size
/// InkCanvasEditor(notebook: notebook)
/// ```
@MainActor
public final class InkNotebook: ObservableObject {
    @Published public private(set) var pages: [CanvasDocument]
    @Published public private(set) var currentPageIndex: Int = 0
    /// Size used for new pages when none is given and there is no current page to copy.
    public var defaultPageSize: PageSize
    /// Template used for new pages when there is no page to copy.
    public var defaultTemplate: PageTemplate
    /// Bookmarked pages and the outline's entries (see `NoteOutline`). Entries for pages that have been
    /// removed stay until the host prunes them when it saves; the outline panel doesn't show them.
    @Published public var outline = NoteOutline()

    /// A notebook of `pageCount` blank pages of `pageSize` on `template` (at least one).
    public init(pageSize: PageSize = .default, pageCount: Int = 1, template: PageTemplate = .default) {
        defaultPageSize = pageSize
        defaultTemplate = template
        pages = (0 ..< max(1, pageCount)).map { _ in CanvasDocument(pageSize: pageSize, template: template) }
    }

    /// A notebook over existing pages. An empty array gets one blank page of `defaultPageSize`.
    public init(pages: [CanvasDocument], defaultPageSize: PageSize = .default, defaultTemplate: PageTemplate = .default) {
        self.defaultPageSize = defaultPageSize
        self.defaultTemplate = defaultTemplate
        self.pages = pages.isEmpty ? [CanvasDocument(pageSize: defaultPageSize, template: defaultTemplate)] : pages
    }

    public var pageCount: Int {
        pages.count
    }

    public var currentPage: CanvasDocument {
        pages[currentPageIndex]
    }

    public var canGoToPreviousPage: Bool {
        currentPageIndex > 0
    }

    public var canGoToNextPage: Bool {
        currentPageIndex < pages.count - 1
    }

    public var canRemovePage: Bool {
        pages.count > 1
    }

    /// Index of the page with `id`, if it's in this notebook.
    public func index(of id: CanvasDocument.ID) -> Int? {
        pages.firstIndex { $0.id == id }
    }

    // MARK: Navigation

    /// Shows the page at `index`, clamped to the valid range.
    public func goToPage(_ index: Int) {
        let clamped = min(max(index, 0), pages.count - 1)
        if clamped != currentPageIndex {
            currentPageIndex = clamped
        }
    }

    public func goToNextPage() {
        goToPage(currentPageIndex + 1)
    }

    public func goToPreviousPage() {
        goToPage(currentPageIndex - 1)
    }

    // MARK: Editing

    /// Inserts a blank page after the current one and shows it. Its size is `size`, or else the current
    /// page's size, so a notebook stays uniform unless asked otherwise. It's on the current page's template.
    @discardableResult
    public func addPage(size: PageSize? = nil) -> CanvasDocument {
        insertPage(at: currentPageIndex + 1, size: size)
    }

    /// Inserts a blank page at `index` (clamped to `0...pageCount`) and shows it. It takes its neighbour's
    /// template, and without `size` its size too: the page before it, or for a new first page the page after it.
    @discardableResult
    public func insertPage(at index: Int, size: PageSize? = nil) -> CanvasDocument {
        let i = min(max(index, 0), pages.count)
        let neighbour = i > 0 ? pages[i - 1] : pages.first
        let page = CanvasDocument(pageSize: size ?? neighbour?.pageSize ?? defaultPageSize,
                                  template: neighbour?.template ?? defaultTemplate,
                                  templateArtwork: neighbour?.templateArtwork)
        pages.insert(page, at: i)
        currentPageIndex = i
        return page
    }

    /// Inserts an existing page (for example one restored from disk) at `index` and shows it.
    /// Does nothing if the page is already in the notebook.
    public func insert(_ page: CanvasDocument, at index: Int) {
        guard self.index(of: page.id) == nil else { return }
        let i = min(max(index, 0), pages.count)
        pages.insert(page, at: i)
        currentPageIndex = i
    }

    /// Removes the page at `index` and returns it. The last remaining page can't be removed.
    /// The current page stays current if it survives; otherwise the page that took its place is shown.
    @discardableResult
    public func removePage(at index: Int) -> CanvasDocument? {
        guard pages.count > 1, pages.indices.contains(index) else { return nil }
        let removed = pages.remove(at: index)
        if index < currentPageIndex || currentPageIndex >= pages.count {
            currentPageIndex -= 1
        }
        return removed
    }

    /// Moves a page from `source` to `destination` (both indices into the current array, the destination
    /// clamped to the valid range). The page that was current stays current.
    public func movePage(from source: Int, to destination: Int) {
        guard pages.indices.contains(source) else { return }
        let target = min(max(destination, 0), pages.count - 1)
        guard target != source else { return }
        let current = currentPage.id
        pages.insert(pages.remove(at: source), at: target)
        currentPageIndex = index(of: current) ?? 0
    }

    // MARK: Several pages at once

    /// Moves the pages at `offsets` so they sit together, in their order, before the page that was at
    /// `destination` (`pageCount` for the end), like `Array.move(fromOffsets:toOffset:)`. The page that
    /// was current stays current.
    public func movePages(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let valid = offsets.filteredIndexSet { pages.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let current = currentPage.id
        var reordered = pages
        reordered.move(fromOffsets: valid, toOffset: min(max(destination, 0), pages.count))
        guard reordered.map(\.id) != pages.map(\.id) else { return }
        pages = reordered
        currentPageIndex = index(of: current) ?? 0
    }

    /// Puts a copy of each page at `offsets` right after it, and returns the copies. The current page
    /// stays current.
    @discardableResult
    public func duplicatePages(at offsets: IndexSet) -> [CanvasDocument] {
        let current = currentPage.id
        var copies: [CanvasDocument] = []
        // Last first, so inserting a copy never shifts a page still to copy.
        for i in offsets.reversed() where pages.indices.contains(i) {
            let copy = pages[i].copy()
            pages.insert(copy, at: i + 1)
            copies.insert(copy, at: 0)
        }
        currentPageIndex = index(of: current) ?? 0
        return copies
    }

    /// Whether the pages at `offsets` can be removed: a notebook keeps at least one page.
    public func canRemovePages(at offsets: IndexSet) -> Bool {
        let count = offsets.filter { pages.indices.contains($0) }.count
        return count > 0 && count < pages.count
    }

    /// Removes the pages at `offsets` and returns them, unless that would leave no pages. The current
    /// page stays current if it survives; otherwise the first page after the removed ones is shown.
    @discardableResult
    public func removePages(at offsets: IndexSet) -> [CanvasDocument] {
        let valid = offsets.filteredIndexSet { pages.indices.contains($0) }
        guard canRemovePages(at: valid) else { return [] }
        let current = currentPage.id
        let removedBeforeCurrent = valid.filter { $0 < currentPageIndex }.count
        let removed = valid.map { pages[$0] }
        pages.remove(atOffsets: valid)
        currentPageIndex = index(of: current) ?? min(currentPageIndex - removedBeforeCurrent, pages.count - 1)
        return removed
    }

    /// Turns each page at `offsets` a quarter turn, ink and all (see `CanvasDocument.rotate(clockwise:)`).
    public func rotatePages(at offsets: IndexSet, clockwise: Bool = true) {
        objectWillChange.send()
        for i in offsets where pages.indices.contains(i) {
            pages[i].rotate(clockwise: clockwise)
        }
    }

    /// Adds existing pages (copied from another notebook, say) at the end, without changing the current
    /// page. Pages already in the notebook are skipped.
    public func appendPages(_ newPages: [CanvasDocument]) {
        let fresh = newPages.filter { index(of: $0.id) == nil }
        guard !fresh.isEmpty else { return }
        pages.append(contentsOf: fresh)
    }

    // MARK: Writing off the end

    /// How far down the last page ink has to reach (as a fraction of its height) for a new page to be
    /// added after it in continuous scrolling.
    public static let autoAddPageThreshold: CGFloat = 0.85

    /// In continuous scrolling, writing near the bottom of the last page adds a blank page after it, so
    /// there's always somewhere to carry on. Call with the bounds (canvas space) of ink just committed on
    /// `page`; returns the page added, if any. The current page doesn't change.
    @discardableResult
    public func addPageIfWritingReachedEnd(of page: CanvasDocument, inkBounds: CGRect) -> CanvasDocument? {
        guard page.id == pages.last?.id, !inkBounds.isNull,
              inkBounds.maxY >= page.pageSize.height * Self.autoAddPageThreshold
        else { return nil }
        let newPage = CanvasDocument(pageSize: page.pageSize, template: page.template,
                                     templateArtwork: page.templateArtwork)
        pages.append(newPage)
        return newPage
    }

    /// Changes the size of the page at `index`; existing ink keeps its position.
    public func setPageSize(_ size: PageSize, forPageAt index: Int) {
        guard pages.indices.contains(index) else { return }
        objectWillChange.send()
        pages[index].pageSize = size
    }

    /// Changes every page to `size` and makes it the default for new pages.
    public func setPageSizeForAllPages(_ size: PageSize) {
        objectWillChange.send()
        defaultPageSize = size
        for page in pages {
            page.pageSize = size
        }
    }

    /// Puts the page at `index` on `template` (with `artwork` for a custom background).
    public func setTemplate(_ template: PageTemplate, artwork: TemplateArtwork? = nil, forPageAt index: Int) {
        guard pages.indices.contains(index) else { return }
        objectWillChange.send()
        pages[index].setTemplate(template, artwork: artwork)
    }

    /// Puts every page on `template` and makes it the default for new pages.
    public func setTemplateForAllPages(_ template: PageTemplate, artwork: TemplateArtwork? = nil) {
        objectWillChange.send()
        defaultTemplate = template.background == nil ? template : defaultTemplate
        for page in pages {
            page.setTemplate(template, artwork: artwork)
        }
    }
}
