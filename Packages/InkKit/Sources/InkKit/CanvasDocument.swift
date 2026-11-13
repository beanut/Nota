import CoreGraphics
import Foundation

/// One page: its paper size, stroke list and undo/redo command stack.
@MainActor
public final class CanvasDocument: Identifiable {
    public let id: UUID

    /// Paper size of the page. Strokes are kept where they are when it changes, so ink beyond the new
    /// edge is hidden rather than deleted and comes back if the page grows again.
    public var pageSize: PageSize {
        didSet {
            if pageSize != oldValue {
                revision += 1
                for observer in liveObservers() {
                    observer.onPageSizeChange()
                }
            }
        }
    }

    /// The page in canvas space: `(0, 0)` to `(width, height)`.
    public var pageBounds: CGRect {
        pageSize.bounds
    }

    public init(pageSize: PageSize = .default, id: UUID = UUID()) {
        self.id = id
        self.pageSize = pageSize
    }

    /// True when `point` (canvas space) is on the page.
    public func contains(_ point: CGPoint) -> Bool {
        pageBounds.contains(point)
    }

    /// Goes up whenever the page's ink or size changes (each edit, undo and redo), so a cached rendering
    /// of the page is current while its revision matches.
    public private(set) var revision = 0 {
        didSet {
            if committedRaster?.revision != revision {
                committedRaster = nil
            }
        }
    }

    /// The page's committed layer as the canvas last showed it, fitted, for reopening it without
    /// filling every stroke again. Dropped as soon as the page changes.
    var committedRaster: CommittedRaster?

    /// Number of strokes on the page (including pixel-eraser strokes).
    public var strokeCount: Int {
        strokes.count
    }

    struct Removal {
        let index: Int
        let stroke: Stroke
    }

    /// A stroke replaced by the pieces a pixel eraser cut it into. `index` is its position in `strokes`
    /// before the command applied.
    struct Split {
        let index: Int
        let original: Stroke
        let pieces: [Stroke]
    }

    enum Command {
        case add(Stroke, splits: [Split]) // splits: strokes the added pixel-eraser stroke cut apart
        case erase([Removal]) // in removal order; undo re-inserts in reverse
        case clear([Stroke])
        case move(Set<UUID>, CGPoint) // translate strokes by a canvas-space delta
    }

    private(set) var strokes: [Stroke] = []
    private var undoStack: [Command] = []
    private var redoStack: [Command] = []

    /// What a change to the page was, for the views showing it.
    enum Change {
        /// Strokes were added, removed or moved, or the page was cleared; the undo state may have changed.
        case edited
        /// A late estimated-property update refined one committed stroke's points.
        case refined
    }

    /// A view showing the page. The same page can be on screen more than once (a note open in two
    /// windows), so every view showing it hears about each change, including those made by another view.
    private struct Observer {
        weak var owner: AnyObject?
        let onChange: (Change) -> Void
        let onPageSizeChange: () -> Void
    }

    private var observers: [Observer] = []

    /// Calls `onChange` after every edit, undo, redo and refinement of the page, and `onPageSizeChange`
    /// after it's resized, until `owner` is released or `removeObserver(_:)` is called. Observing again
    /// with the same owner replaces its handlers.
    func addObserver(_ owner: AnyObject, onChange: @escaping (Change) -> Void,
                     onPageSizeChange: @escaping () -> Void = {}) {
        removeObserver(owner)
        observers.append(Observer(owner: owner, onChange: onChange, onPageSizeChange: onPageSizeChange))
    }

    func removeObserver(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    /// Number of views observing the page.
    var observerCount: Int {
        observers.filter { $0.owner != nil }.count
    }

    private func liveObservers() -> [Observer] {
        observers.removeAll { $0.owner == nil }
        return observers
    }

    private func notify(_ change: Change) {
        for observer in liveObservers() {
            observer.onChange(change)
        }
    }

    /// Strokes whose points changed in place in the most recent change (moved by a lasso, its undo or
    /// redo, or refined by a late estimate), so a view can invalidate their cached geometry.
    private(set) var lastReshapedIDs: Set<UUID> = []
    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    /// Appends a stroke. For a pixel-eraser stroke, `splits` replaces each stroke it cut through with
    /// its pieces in the same undoable command, so undo restores the original in one step.
    func add(_ stroke: Stroke, splits: [Split] = []) {
        apply(splits)
        strokes.append(stroke)
        push(.add(stroke, splits: splits))
    }

    /// Removes strokes immediately (live erasing) without recording a command.
    /// Call `recordErase` once with everything removed during the gesture.
    func remove(ids: Set<UUID>) -> [Removal] {
        var removed: [Removal] = []
        for i in strokes.indices.reversed() where ids.contains(strokes[i].id) {
            removed.append(Removal(index: i, stroke: strokes.remove(at: i)))
        }
        return removed
    }

    func recordErase(_ removals: [Removal]) {
        guard !removals.isEmpty else { return }
        push(.erase(removals))
    }

    /// Translates strokes immediately (live dragging) without recording a command.
    func translate(ids: Set<UUID>, by d: CGPoint) {
        for i in strokes.indices where ids.contains(strokes[i].id) {
            for j in strokes[i].points.indices {
                strokes[i].points[j].location.x += d.x
                strokes[i].points[j].location.y += d.y
            }
        }
    }

    func recordMove(ids: Set<UUID>, by d: CGPoint) {
        guard !ids.isEmpty, d != .zero else { return }
        push(.move(ids, d), reshaping: ids)
    }

    func clear() {
        guard !strokes.isEmpty else { return }
        let saved = strokes
        strokes.removeAll()
        push(.clear(saved))
    }

    /// Applies a late estimated-property update (force/tilt refinement) to a committed stroke.
    func updatePoint(strokeID: UUID, index: Int, _ body: (inout StrokePoint) -> Void) -> Bool {
        guard let s = strokes.lastIndex(where: { $0.id == strokeID }),
              strokes[s].points.indices.contains(index) else { return false }
        body(&strokes[s].points[index])
        revision += 1
        lastReshapedIDs = [strokeID]
        notify(.refined)
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let command = undoStack.popLast() else { return false }
        lastReshapedIDs = []
        switch command {
        case let .add(stroke, splits):
            if let i = strokes.lastIndex(where: { $0.id == stroke.id }) {
                redoStack.append(.add(strokes.remove(at: i), splits: splits))
                revert(splits)
            }
        case let .erase(removals):
            for r in removals.reversed() {
                strokes.insert(r.stroke, at: min(r.index, strokes.count))
            }
            redoStack.append(.erase(removals))
        case let .clear(saved):
            strokes = saved
            redoStack.append(.clear(saved))
        case let .move(ids, d):
            translate(ids: ids, by: CGPoint(x: -d.x, y: -d.y))
            lastReshapedIDs = ids
            redoStack.append(.move(ids, d))
        }
        revision += 1
        notify(.edited)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let command = redoStack.popLast() else { return false }
        lastReshapedIDs = []
        switch command {
        case let .add(stroke, splits):
            apply(splits)
            strokes.append(stroke)
            undoStack.append(.add(stroke, splits: splits))
        case let .erase(removals):
            let again = remove(ids: Set(removals.map(\.stroke.id)))
            undoStack.append(.erase(again))
        case .clear:
            undoStack.append(.clear(strokes))
            strokes.removeAll()
        case let .move(ids, d):
            translate(ids: ids, by: d)
            lastReshapedIDs = ids
            undoStack.append(.move(ids, d))
        }
        revision += 1
        notify(.edited)
        return true
    }

    /// Highest index first, so replacing one stroke never shifts the index of another still to apply.
    private func apply(_ splits: [Split]) {
        for split in splits.sorted(by: { $0.index > $1.index }) {
            guard strokes.indices.contains(split.index), strokes[split.index].id == split.original.id else {
                assertionFailure("split target moved"); continue
            }
            strokes.replaceSubrange(split.index ... split.index, with: split.pieces)
        }
    }

    /// Lowest index first: once the earlier splits are reverted, each one's pieces start at its `index`.
    private func revert(_ splits: [Split]) {
        for split in splits.sorted(by: { $0.index < $1.index }) {
            let range = split.index ..< (split.index + split.pieces.count)
            guard range.upperBound <= strokes.count,
                  zip(strokes[range], split.pieces).allSatisfy({ $0.id == $1.id })
            else {
                assertionFailure("split pieces moved"); continue
            }
            strokes.replaceSubrange(range, with: [split.original])
        }
    }

    private func push(_ command: Command, reshaping reshaped: Set<UUID> = []) {
        undoStack.append(command)
        redoStack.removeAll()
        lastReshapedIDs = reshaped
        revision += 1
        notify(.edited)
    }
}
