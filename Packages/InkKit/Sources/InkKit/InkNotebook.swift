import Combine
import Foundation

/// An ordered stack of pages, each a `CanvasDocument` with its own paper size and undo history.
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

    /// A notebook of `pageCount` blank pages of `pageSize` (at least one).
    public init(pageSize: PageSize = .default, pageCount: Int = 1) {
        defaultPageSize = pageSize
        pages = (0 ..< max(1, pageCount)).map { _ in CanvasDocument(pageSize: pageSize) }
    }

    /// A notebook over existing pages. An empty array gets one blank page of `defaultPageSize`.
    public init(pages: [CanvasDocument], defaultPageSize: PageSize = .default) {
        self.defaultPageSize = defaultPageSize
        self.pages = pages.isEmpty ? [CanvasDocument(pageSize: defaultPageSize)] : pages
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
    /// page's size, so a notebook stays uniform unless asked otherwise.
    @discardableResult
    public func addPage(size: PageSize? = nil) -> CanvasDocument {
        insertPage(at: currentPageIndex + 1, size: size)
    }

    /// Inserts a blank page at `index` (clamped to `0...pageCount`) and shows it. Without `size` it takes
    /// the size of its neighbour: the page before it, or for a new first page the page after it.
    @discardableResult
    public func insertPage(at index: Int, size: PageSize? = nil) -> CanvasDocument {
        let i = min(max(index, 0), pages.count)
        let neighbour = i > 0 ? pages[i - 1] : pages.first
        let page = CanvasDocument(pageSize: size ?? neighbour?.pageSize ?? defaultPageSize)
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
}
