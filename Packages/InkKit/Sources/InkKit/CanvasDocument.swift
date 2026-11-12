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
                onPageSizeChange?()
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

    var onPageSizeChange: (() -> Void)?

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

    var onChange: (() -> Void)?
    /// Strokes moved by the most recent undo/redo, so the view can invalidate their cached geometry.
    private(set) var lastMovedIDs: Set<UUID> = []
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
        push(.move(ids, d))
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
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let command = undoStack.popLast() else { return false }
        lastMovedIDs = []
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
            lastMovedIDs = ids
            redoStack.append(.move(ids, d))
        }
        onChange?()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let command = redoStack.popLast() else { return false }
        lastMovedIDs = []
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
            lastMovedIDs = ids
            undoStack.append(.move(ids, d))
        }
        onChange?()
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

    private func push(_ command: Command) {
        undoStack.append(command)
        redoStack.removeAll()
        onChange?()
    }
}
