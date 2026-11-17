import CoreGraphics
import Foundation
@testable import InkKit
import Testing

private let hasMetal = WaxRenderer.shared != nil

/// A wavy stroke from `x0` at `y`, of `brush`.
private func wave(x0: CGFloat = 20, y: CGFloat, length: Int = 40, brush: BrushDescriptor = TestBrush.pen.brush(width: 4),
                  color: RGBA = RGBA.swatches[0], seed: Int = 0) -> Stroke {
    let points = (0 ..< length).map { i in
        StrokePoint(location: CGPoint(x: x0 + CGFloat(i) * 8, y: y + 18 * sin(CGFloat(i + seed) * 0.33)),
                    force: 0.3 + 0.6 * CGFloat((i + seed) % 7) / 7, altitude: 0.3 + CGFloat(i % 5) * 0.25,
                    azimuth: CGFloat(i) * 0.2, timestamp: Double(i) / 240)
    }
    return Stroke(id: UUID(), color: color, brush: brush, points: points,
                  createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(seed)))
}

/// A page of strokes crossing each other and the tile edges, every third of `kind` (the rest pen ink, so
/// an eraser has something to erase).
private func page(of kind: TileInk, count: Int = 18) -> [Stroke] {
    (0 ..< count).map { n in
        let brush = n % 3 == 2 ? kind.brush() : TestBrush.pen.brush(width: 3)
        let color = brush.blend == .multiply ? RGBA(r: 1, g: 0.85, b: 0.2) : RGBA.swatches[n % RGBA.swatches.count]
        return wave(x0: CGFloat(n * 53 % 120) + 5, y: CGFloat(n * 61 % 560) + 30, length: 44, brush: brush, color: color,
                    seed: n)
    }
}

private func snapshot(_ strokes: [Stroke]) -> InkSnapshot {
    InkSnapshot(strokes: strokes, index: StrokeIndex(strokes: strokes),
                geometry: Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, StrokeRenderer.geometry(for: $0)) }),
                skipped: [])
}

/// A tile's bytes, zeros for an empty one, so an emptied tile compares equal to one never drawn.
private func pixels(_ image: CGImage?) -> Data {
    guard let image, let data = image.dataProvider?.data as Data? else {
        return Data(count: TileKey.side * TileKey.side * 4)
    }
    return data
}

/// Whether two tiles are the same picture: no channel more than one level apart (what a region refill's
/// clip can move Core Graphics' coverage by), in no more than 0.5% of the pixels.
private func sameTile(_ a: CGImage?, _ b: CGImage?) -> Bool {
    let x = pixels(a), y = pixels(b)
    guard x.count == y.count else { return false }
    if x == y {
        return true
    }
    var differing = 0, worst = 0
    x.withUnsafeBytes { px in
        y.withUnsafeBytes { py in
            let p = px.bindMemory(to: UInt8.self), q = py.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 < p.count {
                var d = 0
                for c in 0 ..< 4 {
                    d = max(d, abs(Int(p[i + c]) - Int(q[i + c])))
                }
                if d > 0 {
                    differing += 1
                    worst = max(worst, d)
                }
                i += 4
            }
        }
    }
    return worst <= 1 && differing * 200 <= x.count / 4
}

/// `key`'s tile at `before`, brought to `after` by refilling only where `changed` reaches it, as a
/// region refill job does.
private func refilled(_ key: TileKey, from before: InkSnapshot, to after: InkSnapshot, changed: CGRect) -> CGImage? {
    let base = RenderCoordinator.draw(key, from: before, revision: 0, filler: CoreGraphicsTileFiller())
    guard changed.intersects(key.rect) else { return base.image }
    let region = TileBitmap.pixelAligned(changed.intersection(key.rect), in: key)
    guard let ctx = TileBitmap.context(for: key, startingFrom: base.image) else { return nil }
    let strokes = after.drawable(in: TileBitmap.strokeQuery(for: region, level: key.level))
    CoreGraphicsTileFiller().fill(key, region: region, strokes: strokes, into: ctx)
    return ctx.makeImage()
}

/// Dirty rects (NOT-104): a page's changes logged with where they touched, and tiles brought up to date
/// by refilling only there, giving the tiles a fill from scratch gives (`sameTile`).
@Suite("Dirty-rect edits")
struct DirtyRectTests {
    static let size = CGSize(width: 480, height: 640)

    // MARK: The change log

    @Test func theLogKnowsWhatChangedBetweenTwoVersions() {
        var log = InkChangeLog()
        log.append(version: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        log.append(version: 2, rect: .null) // a change that touched no ink
        log.append(version: 3, rect: CGRect(x: 100, y: 100, width: 10, height: 10))
        #expect(log.version == 3)
        #expect(log.changes(from: 0, to: 3)?.count == 2)
        #expect(log.changes(from: 1, to: 2) == [])
        #expect(log.changes(from: 3, to: 3) == [])
        #expect(log.changes(from: 2, to: 3) == [CGRect(x: 99, y: 99, width: 12, height: 12)]) // padded
        let tile = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(log.dirtyRect(in: tile, from: 0, to: 3) == CGRect(x: 0, y: 0, width: 11, height: 11))
        #expect(log.dirtyRect(in: tile, from: 1, to: 3) == .null)
        #expect(log.changes(from: 3, to: 4) == nil) // not yet
        log.append(version: 4, rect: nil) // the page resized: anything
        #expect(log.changes(from: 3, to: 4) == nil)
        #expect(log.changes(from: 0, to: 3) != nil)
        for v in 5 ... 4 + InkChangeLog.capacity {
            log.append(version: v, rect: .null)
        }
        #expect(log.base == 4)
        #expect(log.changes(from: 3, to: log.version) == nil) // older than the log
        #expect(log.changes(from: 4, to: log.version) == [])
    }

    @Test func aChangeIsTheReachOfTheStrokesThatDiffer() {
        let strokes = (0 ..< 6).map { wave(y: CGFloat(40 + $0 * 100), seed: $0) }
        let reach = strokes.map(StrokeIndex.reach(of:))
        // Recoloured in place: that stroke only.
        var recoloured = strokes
        recoloured[3].color = RGBA(r: 0.7, g: 0.2, b: 0.5)
        #expect(InkChangeLog.changedReach(from: strokes, to: recoloured) == reach[3])
        // Brought to the front: everything it moved past (their order against it changed).
        let front = strokes.filter { $0.id != strokes[1].id } + [strokes[1]]
        #expect(InkChangeLog.changedReach(from: strokes, to: front) == reach[1 ... 5].reduce(CGRect.null) { $0.union($1) })
        // Two strokes cut into pieces (a standard erase), the rest in place: the originals and the pieces.
        let pieces = [wave(x0: 20, y: 140, length: 10), wave(x0: 200, y: 140, length: 10)]
        let cut = Array(strokes[0 ..< 1]) + pieces + Array(strokes[2 ..< 4]) + Array(strokes[5...])
        let expected = [reach[1], reach[4]] + pieces.map(StrokeIndex.reach(of:))
        #expect(InkChangeLog.changedReach(from: strokes, to: cut) == expected.reduce(CGRect.null) { $0.union($1) })
        #expect(InkChangeLog.changedReach(from: strokes, to: strokes) == .null)
    }

    @MainActor
    @Test func everyInkChangeMovesTheInkVersionAndLogsWhereItWent() {
        let doc = CanvasDocument(pageSize: .letter)
        let a = wave(y: 100), b = wave(y: 400, seed: 3)
        var version = doc.inkVersion
        func expectChange(_ strokes: [Stroke], _ what: Comment) {
            #expect(doc.inkVersion == version + 1, what)
            let changed = doc.inkChanges.changes(from: version, to: doc.inkVersion) ?? []
            let union = changed.reduce(CGRect.null) { $0.union($1) }
            for stroke in strokes {
                #expect(union.contains(StrokeIndex.reach(of: stroke)), what)
            }
            version = doc.inkVersion
        }
        doc.add(a)
        expectChange([a], "add")
        doc.add(b)
        expectChange([b], "add")
        doc.undo()
        expectChange([b], "undo")
        doc.redo()
        expectChange([b], "redo")
        // Live erasing moves the ink version at each step, though the revision waits for the command.
        let revision = doc.revision
        let removed = doc.remove(ids: [a.id])
        expectChange([a], "live erase")
        #expect(doc.revision == revision)
        doc.recordErase(removed) // nothing more changed: no new version
        #expect(doc.inkVersion == version)
        #expect(doc.revision == revision + 1)
        doc.undo()
        expectChange([a], "undo erase")
        // A lasso drag: each preview step, then the commit (same place as the last step: nothing new).
        let session = doc.beginTransform(PageSelection(strokeIDs: [a.id]))
        let moved = CGAffineTransform(translationX: 30, y: 200)
        doc.previewTransform(session, by: moved)
        expectChange([a, a.applying(moved)], "drag")
        doc.commitTransform(session, by: moved)
        #expect(doc.inkVersion == version)
        doc.restyle(PageSelection(strokeIDs: [b.id]), strokes: { var s = $0; s.color = RGBA(r: 0.2, g: 0.3, b: 0.9); return s },
                    objects: { $0 })
        expectChange([b], "recolour")
        // Objects aren't in the committed ink: no new version.
        doc.addObject(PlaceholderObject(frame: CGRect(x: 10, y: 10, width: 50, height: 50), color: PenColor(rgb: 0x202020)))
        #expect(doc.inkVersion == version)
        // A change no rect describes.
        doc.pageSize = .a4
        #expect(doc.inkVersion == version + 1)
        #expect(doc.inkChanges.changes(from: version, to: doc.inkVersion) == nil)
    }

    // MARK: Region refills

    /// Erasing, moving and recolouring strokes, then refilling only the changed region of each tile over
    /// its old pixels, gives the tiles drawn from scratch (to a level in a few pixels, `sameTile`): every
    /// kind of ink, at a level whose tiles don't fall on whole points.
    @Test(arguments: TileInk.allCases)
    func aRegionRefillIsTheTileDrawnFromScratch(_ kind: TileInk) {
        guard kind != .crayon || hasMetal else { return }
        let before = page(of: kind)
        var after = before
        after.remove(at: 4) // erased
        after[7] = after[7].applying(CGAffineTransform(translationX: 23.3, y: -41.7)) // moved
        after[10].color = RGBA(r: 0.1, g: 0.6, b: 0.3) // recoloured
        after[2] = after[2].applying(CGAffineTransform(rotationAngle: 0.1)) // turned (one of `kind`)
        let changed = InkChangeLog.changedReach(from: before, to: after).insetBy(dx: -InkChangeLog.padding,
                                                                                 dy: -InkChangeLog.padding)
        let old = snapshot(before), new = snapshot(after)
        for level in [TileLevel(pixelsPerPoint: 2), TileLevel(pixelsPerPoint: 2.37)] {
            let keys = TileKey.keys(covering: CGRect(origin: .zero, size: Self.size), page: UUID(), level: level)
            var refilledTiles = 0
            for key in keys {
                let expected = RenderCoordinator.draw(key, from: new, revision: 0, filler: CoreGraphicsTileFiller())
                let got = refilled(key, from: old, to: new, changed: changed)
                if changed.intersects(key.rect), TileBitmap.pixelAligned(changed.intersection(key.rect), in: key) != key.rect {
                    refilledTiles += 1
                }
                #expect(sameTile(got, expected.image), "\(kind) tile \(key.col),\(key.row) at \(level.pixelsPerPoint)")
            }
            #expect(refilledTiles > 0)
        }
    }

    @Test func pixelAlignedRegionsFallBetweenPixels() {
        let key = TileKey(page: UUID(), level: TileLevel(pixelsPerPoint: 2.5), col: 1, row: 2)
        let region = TileBitmap.pixelAligned(CGRect(x: 110.1, y: 210.3, width: 20, height: 5), in: key)
        for edge in [region.minX, region.minY, region.maxX, region.maxY] {
            let px = edge * 2.5
            #expect(abs(px - px.rounded()) < 1e-9)
        }
        #expect(region.contains(CGRect(x: 110.1, y: 210.3, width: 20, height: 5)))
        #expect(TileBitmap.pixelAligned(key.rect.insetBy(dx: -5, dy: -5), in: key) == key.rect)
        #expect(TileBitmap.pixelAligned(CGRect(x: 0, y: 0, width: 5, height: 5), in: key) == .null)
    }
}

/// Records which tiles a fill drew and whether only a region of each.
private final class RecordingFiller: TileFiller, @unchecked Sendable { // guarded by `lock`
    private let lock = NSLock()
    private var log: [(key: TileKey, region: CGRect?)] = []

    var fills: [(key: TileKey, region: CGRect?)] {
        lock.withLock { log }
    }

    func reset() {
        lock.withLock { log = [] }
    }

    func fill(_ key: TileKey, region: CGRect?, strokes: [TileStroke], into ctx: CGContext,
              isCancelled: () -> Bool) -> Int {
        lock.withLock { log.append((key, region)) }
        return CoreGraphicsTileFiller().fill(key, region: region, strokes: strokes, into: ctx, isCancelled: isCancelled)
    }
}

/// Just enough of a canvas to host a coordinator.
@MainActor
private final class Host: RenderCoordinatorHost {
    var renderTransform = ViewTransform(scale: 1.3, offset: .zero)
    var renderBounds = CGRect(x: 0, y: 0, width: 640, height: 840)
    var restingScale: CGFloat = 1.3
    var isMoving = false
    var isEditingInk = false
    var pencilLocation: CGPoint?
    func fittedTransform() -> ViewTransform {
        renderTransform
    }

    func hasOutstandingEstimates(for _: UUID) -> Bool {
        false
    }

    func renderCoordinatorNeedsLayout() {}
    func renderCoordinatorDidPublish() {}
    func renderCoordinatorDidDrawPending(canvasRect _: CGRect) {}
}

@MainActor
private func waitUntil(timeout: TimeInterval = 20, _ done: () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done() {
        guard Date() < deadline else {
            Issue.record("timed out")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Edits on a coordinator: tiles refilled only where an edit reached, ending up as the tiles drawn
/// from scratch after any sequence of edits, undos and redos.
@MainActor
@Suite("Dirty-rect edits on the canvas", .serialized)
struct DirtyRectCoordinatorTests {
    let document = CanvasDocument(pageSize: .letter)
    private let host = Host()
    let cache = TileCache(byteBudget: 128 << 20)
    private let filler = RecordingFiller()

    private func coordinator() -> RenderCoordinator {
        let scheduler = RenderScheduler(limits: .init(idle: 4, gesture: 2, lowPriority: 1), frameInterval: 0)
        let coordinator = RenderCoordinator(document: document, embedded: true, cache: cache, filler: filler,
                                            scheduler: scheduler)
        coordinator.host = host
        coordinator.resize(to: host.renderBounds, scale: 2)
        return coordinator
    }

    private func settle(_ coordinator: RenderCoordinator) async throws {
        coordinator.invalidateAll()
        try await waitUntil { coordinator.isSettled && !coordinator.isFilling }
    }

    /// Every cached tile at the page's version against the same tile drawn from scratch, to a level in a few pixels (`sameTile`).
    private func expectTilesDrawnFromScratch(_ what: String) {
        let ink = snapshot(document.strokes)
        let held = cache.tiles(page: document.cacheID).filter { $0.value.revision == document.inkVersion }
        #expect(!held.isEmpty, "\(what): no tiles")
        for (key, tile) in held {
            let expected = RenderCoordinator.draw(key, from: ink, revision: 0, filler: CoreGraphicsTileFiller())
            guard !sameTile(tile.image, expected.image) else { continue }
            let recent = (max(0, document.inkVersion - 3) ..< document.inkVersion).map { v in
                "\(v)→\(v + 1): \(document.inkChanges.changes(from: v, to: v + 1).map { "\($0)" } ?? "unknown")"
            }
            let tile = "tile \(key.col),\(key.row) at \(key.level.pixelsPerPoint)"
            Issue.record("\(what): \(tile) isn't the tile drawn from scratch; last changes \(recent)")
        }
    }

    @Test func anUndoRefillsOnlyTheRegionItTouchedInTheTilesItReaches() async throws {
        let kinds: [TileInk] = [.plain, .multiRun, .grain, .multiply]
        for (n, kind) in kinds.enumerated() {
            for stroke in page(of: kind, count: 15) {
                document.add(stroke.applying(CGAffineTransform(translationX: 0, y: CGFloat(n) * 4)))
            }
        }
        let coordinator = coordinator()
        try await settle(coordinator)
        let small = wave(x0: 200, y: 300, length: 6, seed: 9)
        document.add(small)
        try await settle(coordinator)
        filler.reset()
        let before = coordinator.fillStats
        document.undo()
        try await settle(coordinator)

        let fills = filler.fills
        let reach = StrokeIndex.reach(of: small)
        #expect(!fills.isEmpty)
        // Only tiles the stroke reached, and only a region of each.
        #expect(fills.allSatisfy { $0.key.rect.intersects(reach.insetBy(dx: -2, dy: -2)) })
        #expect(fills.allSatisfy { fill in
            fill.region.map { $0.width < fill.key.rect.width || $0.height < fill.key.rect.height } ?? false
        })
        #expect(coordinator.fillStats.tilesRefilledInPart - before.tilesRefilledInPart == fills.count)
        expectTilesDrawnFromScratch("after undo")
    }

    /// Random edits of every kind, undone and redone, at two zoom levels: the tiles always end up as
    /// drawn from scratch, and most of the work is region refills.
    @Test func tilesAfterRandomEditsUndosAndRedosAreTheTilesDrawnFromScratch() async throws {
        var rng = SeededRandom(seed: 104)
        let kinds: [TileInk] = [.plain, .multiRun, .grain, .multiply, .eraser]
        for (n, kind) in kinds.enumerated() {
            for stroke in page(of: kind, count: 12) {
                document.add(stroke.applying(CGAffineTransform(translationX: CGFloat(n) * 7, y: CGFloat(n) * 11)))
            }
        }
        let coordinator = coordinator()
        try await settle(coordinator)
        let zoomed = ViewTransform(scale: 2.9, offset: CGPoint(x: -300, y: -500))
        for step in 0 ..< 40 {
            let strokes = document.strokes
            let pick = strokes.isEmpty ? nil : strokes[rng.next(below: strokes.count)]
            let op = rng.next(below: 9)
            switch op {
            case 0:
                document.add(wave(x0: CGFloat(rng.next(below: 300)), y: CGFloat(rng.next(below: 700)),
                                  length: 4 + rng.next(below: 20), seed: step))
            case 1:
                document.undo()
                document.lastReshapedIDs.forEach(coordinator.forgetGeometry) // as the canvas does
            case 2:
                document.redo()
                document.lastReshapedIDs.forEach(coordinator.forgetGeometry)
            case 3:
                if let pick {
                    document.recordErase(document.remove(ids: [pick.id])) // the stroke eraser
                }
            case 4:
                if let pick { // a lasso drag in two steps, then its commit
                    let session = document.beginTransform(PageSelection(strokeIDs: [pick.id]))
                    document.previewTransform(session, by: CGAffineTransform(translationX: 12, y: -8))
                    coordinator.forgetGeometry(pick.id)
                    try await settle(coordinator)
                    let t = CGAffineTransform(translationX: 40, y: 25).rotated(by: 0.2)
                    document.previewTransform(session, by: t)
                    coordinator.forgetGeometry(pick.id)
                    document.commitTransform(session, by: t)
                }
            case 5:
                if let pick {
                    document.restyle(PageSelection(strokeIDs: [pick.id]),
                                     strokes: { var s = $0; s.color = RGBA.swatches[step % RGBA.swatches.count]; return s },
                                     objects: { $0 })
                }
            case 6:
                if let pick {
                    document.arrange(PageSelection(strokeIDs: [pick.id]), step % 2 == 0 ? .bringToFront : .sendToBack)
                }
            case 7:
                if let pick { // a standard erase cutting it in two
                    let before = document.strokes
                    let n = pick.points.count
                    document.replace(id: pick.id, with: n > 6 ? [Stroke(id: UUID(), color: pick.color, brush: pick.brush,
                                                                        points: Array(pick.points[0 ..< n / 3])),
                                                                 Stroke(id: UUID(), color: pick.color, brush: pick.brush,
                                                                        points: Array(pick.points[2 * n / 3 ..< n]))] : [])
                    document.recordReplace(before: before)
                }
            default:
                if let pick { // paste a copy, moved
                    var copy = pick.applying(CGAffineTransform(translationX: 30, y: 30))
                    copy = Stroke(id: UUID(), color: copy.color, brush: copy.brush, points: copy.points)
                    document.insert(strokes: [copy], objects: [])
                }
            }
            if step == 20 { // over to another level and back: its tiles catch up from the log
                host.renderTransform = zoomed
                try await settle(coordinator)
            } else if step == 28 {
                host.renderTransform = ViewTransform(scale: 1.3, offset: .zero)
            }
            try await settle(coordinator)
            expectTilesDrawnFromScratch("step \(step), op \(op)")
        }
        #expect(coordinator.fillStats.tilesRefilledInPart > 0)
    }

    /// Erasing mid-gesture (stroke by stroke, no command yet) brings the tiles up to date at each step,
    /// by region, and the command at the end refills nothing.
    @Test func midEraseEachStepRefillsWhereItErased() async throws {
        for stroke in page(of: .plain, count: 20) {
            document.add(stroke)
        }
        let coordinator = coordinator()
        try await settle(coordinator)
        var removals: [CanvasDocument.Removal] = []
        for victim in document.strokes.prefix(3) {
            filler.reset()
            removals += document.remove(ids: [victim.id])
            try await settle(coordinator)
            let reach = StrokeIndex.reach(of: victim).insetBy(dx: -2, dy: -2)
            #expect(!filler.fills.isEmpty)
            #expect(filler.fills.allSatisfy { $0.key.rect.intersects(reach) })
            expectTilesDrawnFromScratch("mid-erase")
        }
        filler.reset()
        document.recordErase(removals)
        try await settle(coordinator)
        #expect(filler.fills.isEmpty)
    }
}

/// A small deterministic generator, so a failing sequence can be replayed.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next(below bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}
