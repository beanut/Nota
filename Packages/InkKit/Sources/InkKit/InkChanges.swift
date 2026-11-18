import CoreGraphics
import Foundation

/// Where a page's ink changed, version by version (NOT-104): the rect each change touched, so a tile
/// showing an older version is brought up to date by refilling only the part of it that changed, and a
/// tile no change reached is current as it is.
///
/// `CanvasDocument` keeps one. Every change to its strokes moves `CanvasDocument.inkVersion` on by one and
/// logs the union of the ink before and after (each stroke's `StrokeIndex.reach(of:)`, padded for
/// anti-aliasing): commands, their undo and redo, and the changes made mid-gesture that no command
/// describes yet (live erasing, a lasso drag). A change no rect describes (the page resized or rotated)
/// is logged as unknown, and so is anything older than the log keeps.
struct InkChangeLog: Sendable {
    /// How many changes are kept: a tile further behind than that is filled again whole.
    static let capacity = 256
    /// Added to every change's rect: a pixel of anti-aliasing at any level the canvas shows.
    static let padding: CGFloat = 1

    /// The version the oldest kept change started from: changes since are known.
    private(set) var base: Int
    private var entries: [Entry] = []

    private struct Entry {
        let version: Int
        /// Nil: the change may have touched anything.
        let rect: CGRect?
    }

    init(version: Int = 0) {
        base = version
    }

    /// The latest version logged (or `base` when none is).
    var version: Int {
        entries.last?.version ?? base
    }

    /// Logs the change to `version` (the next one), which touched `rect` (nil: anything).
    mutating func append(version: Int, rect: CGRect?) {
        entries.append(Entry(version: version, rect: rect.map { $0.isNull ? $0 : $0.insetBy(dx: -Self.padding, dy: -Self.padding) }))
        if entries.count > Self.capacity {
            base = entries.removeFirst().version
        }
    }

    /// The rects the changes after version `from`, up to and including `to`, touched (none reaching
    /// anything: empty), or nil when they aren't known: `from` is older than the log, or one of them
    /// touched anything.
    func changes(from: Int, to: Int) -> [CGRect]? {
        guard from >= base, from <= to, to <= version else { return nil }
        var rects: [CGRect] = []
        // Newest last: walk back from the end, as a tile is usually only a few changes behind.
        for entry in entries.reversed() {
            if entry.version <= from {
                break
            }
            if entry.version > to {
                continue
            }
            guard let rect = entry.rect else { return nil }
            if !rect.isNull, !rect.isEmpty {
                rects.append(rect)
            }
        }
        return rects
    }

    /// Where the changes after `from` up to `to` reach `rect`: the part of `rect` to refill, `.null` when
    /// none reaches it, or nil when they aren't known.
    func dirtyRect(in rect: CGRect, from: Int, to: Int) -> CGRect? {
        guard let changes = changes(from: from, to: to) else { return nil }
        return changes.reduce(CGRect.null) { dirty, change in
            change.intersects(rect) ? dirty.union(change.intersection(rect)) : dirty
        }
    }

    // MARK: What a change touched

    /// The ink that differs between `old` and `new` (a page's strokes before and after a change), as one
    /// rect: every stroke that's in only one of them, or changed, by its reach. Strokes both keep, in the
    /// same order, aren't counted: the pixels anywhere none of the others reaches are the same in both.
    static func changedReach(from old: [Stroke], to new: [Stroke]) -> CGRect {
        let shared = min(old.count, new.count)
        var prefix = 0
        while prefix < shared, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < shared - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let removed = old[prefix ..< old.count - suffix], added = new[prefix ..< new.count - suffix]
        var rect = CGRect.null
        func include(_ stroke: Stroke) {
            rect = rect.union(StrokeIndex.reach(of: stroke))
        }
        if removed.count == added.count {
            // Restyled or rearranged in place: only the positions that differ.
            for (a, b) in zip(removed, added) where a != b {
                include(a)
                include(b)
            }
            return rect
        }
        // Strokes cut into pieces or put back: those only one side has, or changed, if the rest keep their order.
        let before = Dictionary(removed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterIDs = Set(added.map(\.id))
        var keptBefore: [UUID] = [], keptAfter: [UUID] = []
        for stroke in removed where !afterIDs.contains(stroke.id) {
            include(stroke)
        }
        for stroke in removed where afterIDs.contains(stroke.id) {
            keptBefore.append(stroke.id)
        }
        for stroke in added {
            if let was = before[stroke.id] {
                keptAfter.append(stroke.id)
                if was != stroke {
                    include(was)
                    include(stroke)
                }
            } else {
                include(stroke)
            }
        }
        if keptBefore != keptAfter {
            for stroke in removed {
                include(stroke)
            }
            for stroke in added {
                include(stroke)
            }
        }
        return rect
    }
}
