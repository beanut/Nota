import CoreGraphics
import Foundation

/// Where a page's strokes and objects are: answers "what reaches this rect?" without walking the page.
///
/// Owned by `CanvasDocument`, which keeps it in step with every change to its strokes and objects (each
/// command, its undo and redo, live erasing, previews). Results are positions in the document's arrays, in
/// page (z) order, so drawing them in that order is drawing the page. Each item is filed under a
/// conservative rectangle (for a stroke, `reach(of:)`: never smaller than its ink), so a query returns
/// everything that may reach the rect and callers check exact geometry on what comes back.
///
/// A value type, so a page's copy shares it until either changes, and it can be built off the main actor
/// (`InkPageFile.prepareIndex()`) and handed to the page.
struct StrokeIndex: Sendable {
    private(set) var strokeGrid = SpatialGrid()
    private(set) var objectGrid = SpatialGrid()

    init() {}

    init(strokes: [Stroke], objects: [any PageObject] = []) {
        strokeGrid = SpatialGrid(bounds: strokes.map(Self.reach(of:)))
        objectGrid = SpatialGrid(bounds: objects.map(\.bounds))
    }

    var strokeCount: Int {
        strokeGrid.count
    }

    var objectCount: Int {
        objectGrid.count
    }

    /// Positions (in the page's strokes) of the strokes that may reach `rect`, bottom first.
    func strokes(in rect: CGRect) -> [Int] {
        strokeGrid.query(rect)
    }

    /// Positions (in the page's objects) of the objects that may reach `rect`, bottom first.
    func objects(in rect: CGRect) -> [Int] {
        objectGrid.query(rect)
    }

    /// The rectangle the stroke at `position` is filed under.
    func strokeBounds(at position: Int) -> CGRect {
        strokeGrid.bounds(at: position)
    }

    // MARK: Keeping it in step

    mutating func replaceStrokes(_ range: Range<Int>, with strokes: some Collection<Stroke>) {
        strokeGrid.replaceSubrange(range, with: strokes.map(Self.reach(of:)))
    }

    mutating func updateStroke(at position: Int, to stroke: Stroke) {
        strokeGrid.update(at: position, bounds: Self.reach(of: stroke))
    }

    mutating func replaceObjects(_ range: Range<Int>, with objects: some Collection<any PageObject>) {
        objectGrid.replaceSubrange(range, with: objects.map(\.bounds))
    }

    mutating func updateObject(at position: Int, to object: any PageObject) {
        objectGrid.update(at: position, bounds: object.bounds)
    }

    // MARK: A stroke's reach

    /// A rectangle (page space) holding every pixel `stroke` can draw: its points' bounds grown by the
    /// widest its nib can get. It reads only the points and the brush (no geometry), so it's cheap enough
    /// to work out for every stroke on open and every edit. The nib is widest at full pressure, slow
    /// (a wet brush pools), fully tilted (longer, wider and shifted toward the barrel), with the largest
    /// stamp jitter; a smoothed stroke can bulge past its points by a fraction of its longest step.
    static func reach(of stroke: Stroke) -> CGRect {
        let points = stroke.points
        guard let first = points.first?.location else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        var previous = first, longestStep: CGFloat = 0
        for point in points {
            let p = point.location
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
            longestStep = max(longestStep, abs(p.x - previous.x), abs(p.y - previous.y))
            previous = p
        }
        let pad = padding(for: stroke.brush) + longestStep * 0.5
        guard pad.isFinite, minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return .infinite }
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    /// How far past a point the brush can put ink, in page points (see `reach(of:)`).
    static func padding(for brush: BrushDescriptor) -> CGFloat {
        var radius = max(brush.maxWidth * 0.5, 0.2) * (1 + 0.25 * max(brush.wetness, 0))
        if case let .ellipse(aspect, _) = brush.tip, aspect > 1 {
            radius *= aspect
        }
        let tilt = brush.tilt
        if tilt.enabled {
            let grow = 1 + max(tilt.length, tilt.breadth, 0)
            radius *= grow * (1 + max(tilt.contactShift, 0))
        }
        let jitter = brush.jitter
        let stamp = radius * (1 + 0.5 * max(jitter.size, 0))
        return stamp * (1 + 2 * max(jitter.scatter, 0)) + 1
    }
}

/// A uniform grid of `cellSize`-point cells over items kept in z-order: the structure under `StrokeIndex`.
///
/// Positions are the items' places in the owner's array. Each item has a slot that holds its rectangle
/// and an order key (increasing with position), so inserting or removing items shifts no cell contents:
/// only the two position-ordered arrays move, as the owner's own array does. A query collects the slots of
/// the cells the rect covers, sorts them by order key and maps each back to its position by binary search.
/// Items covering more than `maxCellsPerItem` cells are kept aside and checked on every query.
struct SpatialGrid: Sendable {
    /// About a tile's quarter at the fitted zoom: a 256-pixel tile at 2× is 4 × 4 cells.
    static let cellSize: CGFloat = 32
    static let maxCellsPerItem = 1024

    private struct CellRange {
        var x0, y0, x1, y1: Int32

        var cellCount: Int {
            (Int(x1) - Int(x0) + 1) * (Int(y1) - Int(y0) + 1)
        }

        func forEachKey(_ body: (Int64) -> Void) {
            for y in y0 ... y1 {
                for x in x0 ... x1 {
                    body(SpatialGrid.key(x, y))
                }
            }
        }
    }

    private enum Placement {
        case none // null rect: never found
        case large // in `large`, checked by every query
        case cells(CellRange)
    }

    private struct Slot {
        var bounds: CGRect
        var order: Double
        var placement: Placement
    }

    private var slots: [Slot] = []
    private var freeSlots: [Int32] = []
    /// The slot of the item at each position.
    private var positions: [Int32] = []
    /// `slots[positions[i]].order`: strictly increasing, for finding an item's position from its slot.
    private var orders: [Double] = []
    private var cells: [Int64: [Int32]] = [:]
    private var large: [Int32] = []

    init() {}

    init(bounds: [CGRect]) {
        replaceSubrange(0 ..< 0, with: bounds)
    }

    var count: Int {
        positions.count
    }

    /// The rectangle the item at `position` is filed under.
    func bounds(at position: Int) -> CGRect {
        slots[Int(positions[position])].bounds
    }

    // MARK: Queries

    /// Positions of the items whose rectangles intersect `rect`, in increasing order.
    func query(_ rect: CGRect) -> [Int] {
        guard !positions.isEmpty, !rect.isNull else { return [] }
        // A rect covering more cells than there are items is faster to answer by walking the items.
        guard let range = Self.cellRange(of: rect), range.cellCount <= max(positions.count, 64) else {
            return scan(rect)
        }
        var found: [Int32] = []
        range.forEachKey { key in
            guard let cell = cells[key] else { return }
            for s in cell where slots[Int(s)].bounds.intersects(rect) {
                found.append(s)
            }
        }
        for s in large where slots[Int(s)].bounds.intersects(rect) {
            found.append(s)
        }
        guard !found.isEmpty else { return [] }
        found.sort { slots[Int($0)].order < slots[Int($1)].order }
        var result: [Int] = []
        result.reserveCapacity(found.count)
        var last: Int32 = -1
        for s in found where s != last {
            last = s
            result.append(position(ofOrder: slots[Int(s)].order))
        }
        return result
    }

    private func scan(_ rect: CGRect) -> [Int] {
        positions.indices.filter { slots[Int(positions[$0])].bounds.intersects(rect) }
    }

    private func position(ofOrder order: Double) -> Int {
        var lo = 0, hi = orders.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if orders[mid] < order {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    // MARK: Edits

    /// Replaces the items at `range` with items filed under `newBounds`, as `Array.replaceSubrange` does.
    mutating func replaceSubrange(_ range: Range<Int>, with newBounds: [CGRect]) {
        for p in range {
            let s = positions[p]
            unplace(s)
            freeSlots.append(s)
        }
        let lo = range.lowerBound > 0 ? orders[range.lowerBound - 1] : nil
        let hi = range.upperBound < orders.count ? orders[range.upperBound] : nil
        let (keys, fits) = Self.orderKeys(count: newBounds.count, after: lo, before: hi)
        var newSlots: [Int32] = []
        newSlots.reserveCapacity(newBounds.count)
        for (bounds, order) in zip(newBounds, keys) {
            let s = allocate(Slot(bounds: bounds, order: order, placement: .none))
            place(s)
            newSlots.append(s)
        }
        positions.replaceSubrange(range, with: newSlots)
        orders.replaceSubrange(range, with: keys)
        if !fits {
            renumber()
        }
    }

    mutating func insert(_ bounds: CGRect, at position: Int) {
        replaceSubrange(position ..< position, with: [bounds])
    }

    mutating func remove(at position: Int) {
        replaceSubrange(position ..< position + 1, with: [])
    }

    /// Refiles the item at `position` under `bounds` (it moved or changed shape).
    mutating func update(at position: Int, bounds: CGRect) {
        let s = positions[position]
        guard slots[Int(s)].bounds != bounds else { return }
        unplace(s)
        slots[Int(s)].bounds = bounds
        place(s)
    }

    /// `count` keys strictly between `lo` and `hi` (either may be open), increasing; `fits` is false when
    /// the gap is too narrow for them, and the caller renumbers.
    private static func orderKeys(count: Int, after lo: Double?, before hi: Double?) -> ([Double], fits: Bool) {
        guard count > 0 else { return ([], true) }
        switch (lo, hi) {
        case let (lo?, hi?):
            let step = (hi - lo) / Double(count + 1)
            var keys: [Double] = []
            keys.reserveCapacity(count)
            var previous = lo, fits = true
            for i in 1 ... count {
                let key = lo + step * Double(i)
                if !(key > previous && key < hi) {
                    fits = false
                }
                keys.append(key)
                previous = key
            }
            return (keys, fits)
        case let (lo?, nil):
            return ((1 ... count).map { lo + Double($0) }, true)
        case let (nil, hi?):
            return ((0 ..< count).map { hi - Double(count - $0) }, true)
        case (nil, nil):
            return ((0 ..< count).map(Double.init), true)
        }
    }

    /// Gives every item its position as its order key.
    private mutating func renumber() {
        for (p, s) in positions.enumerated() {
            slots[Int(s)].order = Double(p)
            orders[p] = Double(p)
        }
    }

    private mutating func allocate(_ slot: Slot) -> Int32 {
        if let s = freeSlots.popLast() {
            slots[Int(s)] = slot
            return s
        }
        slots.append(slot)
        return Int32(slots.count - 1)
    }

    private mutating func place(_ s: Int32) {
        let bounds = slots[Int(s)].bounds
        guard !bounds.isNull else {
            slots[Int(s)].placement = .none
            return
        }
        guard let range = Self.cellRange(of: bounds), range.cellCount <= Self.maxCellsPerItem else {
            slots[Int(s)].placement = .large
            large.append(s)
            return
        }
        slots[Int(s)].placement = .cells(range)
        range.forEachKey { key in
            cells[key, default: []].append(s)
        }
    }

    private mutating func unplace(_ s: Int32) {
        switch slots[Int(s)].placement {
        case .none:
            break
        case .large:
            if let i = large.firstIndex(of: s) {
                large.swapAt(i, large.count - 1)
                large.removeLast()
            }
        case let .cells(range):
            range.forEachKey { key in
                guard var cell = cells.removeValue(forKey: key) else { return }
                if let i = cell.firstIndex(of: s) {
                    cell.swapAt(i, cell.count - 1)
                    cell.removeLast()
                }
                if !cell.isEmpty {
                    cells[key] = cell
                }
            }
        }
        slots[Int(s)].placement = .none
    }

    // MARK: Cells

    /// Cells are addressed within ±2³⁰ of the origin; a rect reaching past that (or not finite) has no
    /// cell range and is filed as large.
    private static let cellLimit = CGFloat(1 << 30)

    private static func cellRange(of rect: CGRect) -> CellRange? {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite
        else { return nil }
        let x0 = (rect.minX / cellSize).rounded(.down), x1 = (rect.maxX / cellSize).rounded(.down)
        let y0 = (rect.minY / cellSize).rounded(.down), y1 = (rect.maxY / cellSize).rounded(.down)
        guard x0 > -cellLimit, y0 > -cellLimit, x1 < cellLimit, y1 < cellLimit else { return nil }
        return CellRange(x0: Int32(x0), y0: Int32(y0), x1: Int32(x1), y1: Int32(y1))
    }

    fileprivate static func key(_ x: Int32, _ y: Int32) -> Int64 {
        Int64(x) << 32 | Int64(UInt32(bitPattern: y))
    }
}
