import CoreGraphics
import Foundation

/// One page: its paper size and template, its objects and strokes, and one undo/redo command stack for both.
///
/// The page is drawn in layers: the paper and template, then `objects` (shapes, text, images, tape; see
/// `PageObject`) in `zIndex` order, then the ink, then the selection. Edits to either go on the same
/// stack, so one undo takes back whichever came last, and a lasso transform of ink and objects together
/// is one step.
@MainActor
public final class CanvasDocument: Identifiable {
    public let id: UUID

    /// Paper size of the page. Strokes are kept where they are when it changes, so ink beyond the new
    /// edge is hidden rather than deleted and comes back if the page grows again.
    public var pageSize: PageSize {
        didSet {
            if pageSize != oldValue {
                noteInkChange(nil)
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

    /// What's printed on the page under the ink. Changing it doesn't touch the ink or its undo history,
    /// and doesn't change `revision`: the committed ink layer is drawn without the paper.
    public var template: PageTemplate {
        didSet {
            if template != oldValue {
                notifyTemplateChange()
            }
        }
    }

    /// The bytes of `template.background`, when it has one. Set it before (or with) a template that names
    /// it; artwork whose `id` doesn't match the template's background isn't drawn.
    public var templateArtwork: TemplateArtwork? {
        didSet {
            if templateArtwork !== oldValue {
                notifyTemplateChange()
            }
        }
    }

    public init(pageSize: PageSize = .default, template: PageTemplate = .default,
                templateArtwork: TemplateArtwork? = nil, id: UUID = UUID()) {
        self.id = id
        self.pageSize = pageSize
        self.template = template
        self.templateArtwork = templateArtwork
    }

    /// Puts the page on `template`, with `artwork` as its custom background (nil for none).
    public func setTemplate(_ template: PageTemplate, artwork: TemplateArtwork?) {
        announcesTemplateChanges = false
        templateArtwork = template.background == nil ? nil : artwork
        self.template = template
        announcesTemplateChanges = true
        notifyTemplateChange()
    }

    /// A page holding the ink of a `.ink` file and the objects of its objects file (nil: none), with an
    /// empty undo history. The page takes the ink file's id.
    public convenience init(file: InkPageFile, objects: PageObjectsFile? = nil, pageSize: PageSize) {
        self.init(pageSize: pageSize, id: file.pageID)
        strokes = file.strokes
        preservedRecords = file.unknownRecords
        self.objects = objects?.objects ?? []
        var index = file.preparedIndex ?? StrokeIndex(strokes: strokes)
        index.replaceObjects(0 ..< 0, with: self.objects)
        strokeIndex = index
    }

    /// The page's objects as they are now, ready to encode and write to disk (empty: no file needed).
    /// Objects of kinds this version doesn't know go back out as they came in.
    public var objectsFile: PageObjectsFile {
        PageObjectsFile(pageID: id, objects: objects)
    }

    /// The page's ink as it is now, ready to encode (off the main actor if need be) and write to disk.
    /// Records from a newer format version that the page was opened with go back out with it.
    public var inkFile: InkPageFile {
        InkPageFile(pageID: id, strokes: strokes, unknownRecords: preservedRecords)
    }

    /// Records from the file the page was read from that this version doesn't understand.
    private var preservedRecords: [InkPageFile.UnknownRecord] = []

    /// True when `point` (canvas space) is on the page.
    public func contains(_ point: CGPoint) -> Bool {
        pageBounds.contains(point)
    }

    /// Goes up whenever the page's ink or size changes (each edit, undo and redo), so a cached rendering
    /// of the page is current while its revision matches.
    public private(set) var revision = 0 {
        didSet {
            logInkChange()
        }
    }

    /// Goes up whenever the page's strokes change, mid-gesture too (each step of an erase or a lasso drag,
    /// which `revision` only counts once the gesture is recorded), and when its size does. What the
    /// committed tiles are labelled with: a tile at this version shows the ink as it is. A page read from
    /// its file starts at 0.
    public private(set) var inkVersion = 0

    /// Where each recent change of `inkVersion` touched the ink (NOT-104), so tiles are refilled only there.
    private(set) var inkChanges = InkChangeLog()
    /// What the strokes' changes since `inkVersion` last moved touched; nil: anything.
    private var unloggedChange: CGRect? = .null
    private var hasUnloggedChange = false

    /// The ink in `rect` (nil: anywhere) is changing; `logInkChange()` makes it a version.
    private func noteInkChange(_ rect: CGRect?) {
        if hasUnloggedChange {
            unloggedChange = rect.flatMap { rect in unloggedChange.map { $0.union(rect) } }
        } else {
            unloggedChange = rect
            hasUnloggedChange = true
        }
    }

    /// Moves `inkVersion` on if the strokes changed since it last did, logging where.
    private func logInkChange() {
        guard hasUnloggedChange else { return }
        inkVersion += 1
        inkChanges.append(version: inkVersion, rect: unloggedChange)
        unloggedChange = .null
        hasUnloggedChange = false
    }

    /// The page's resting-level committed tiles, compressed, as the last canvas showing the page left them
    /// (or as the app restored them from its cache), for showing the page again without filling every
    /// stroke (NOT-106). Labelled with the `inkVersion` they show; edits since are caught up from
    /// `inkChanges` tile by tile, so it outlives them. See `TileRaster`.
    var tileRaster: TileRaster? {
        didSet {
            tileRasterGeneration += 1
        }
    }

    /// Goes up each time `tileRaster` is replaced.
    var tileRasterGeneration = 0
    /// Who hears when `tileRaster` is captured (`observeCommittedTiles`).
    var tileObservers: [(owner: () -> AnyObject?, onCapture: () -> Void)] = []

    /// Names this page in the shared `TileCache`. Not the page's `id`: a page read from its file again is
    /// a new document, starting again at revision 0, so the tiles of the old one must not pass for its.
    nonisolated let cacheID = UUID()

    deinit {
        TileCache.shared.removeAll(page: cacheID)
    }

    /// Goes up whenever the page's objects change (each edit, undo and redo that touches them). Separate
    /// from `revision`, which is the ink's: objects aren't in the committed ink layer, so changing one
    /// doesn't drop it.
    public private(set) var objectsRevision = 0

    /// Number of strokes on the page (including pixel-eraser strokes).
    public var strokeCount: Int {
        strokes.count
    }

    /// The page's objects, lowest `zIndex` first. All of them are drawn under the ink.
    public private(set) var objects: [any PageObject] = []

    public var objectCount: Int {
        objects.count
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

    struct ObjectRemoval {
        let index: Int
        let object: any PageObject
    }

    /// Strokes and objects as they were before a transform, and the transform. Undo puts the saved
    /// values back exactly; redo applies the transform to them again, so neither drifts.
    struct Transformation {
        let transform: CGAffineTransform
        let strokes: [Stroke]
        let objects: [any PageObject]

        var strokeIDs: Set<UUID> {
            Set(strokes.map(\.id))
        }
    }

    enum Command {
        case add(Stroke, splits: [Split]) // splits: strokes the added pixel-eraser stroke cut apart
        /// In removal order; undo re-inserts in reverse. Deleting a selection removes objects too.
        case erase([Removal], objects: [ObjectRemoval])
        case clear([Stroke], objects: [any PageObject])
        case replace(before: [Stroke], after: [Stroke]) // a standard erase: strokes cut into what's left
        /// Move, scale or rotate strokes and objects (the lasso and the selection handles).
        case transform(Transformation)
        case addObject(any PageObject)
        /// Paste, duplicate, recolour, change thickness, bring to front or send to back.
        case edit(Edit)
        case replaceObjects(before: [any PageObject], after: [any PageObject]) // reshaped or restyled
    }

    /// An edit given as the page's strokes and objects before and after it (nil: that layer didn't
    /// change). Undo puts the before back and redo the after, exactly. The arrays are copy-on-write and so
    /// are each stroke's points, so keeping both costs little more than what the edit changed.
    struct Edit {
        var strokesBefore: [Stroke]?
        var strokesAfter: [Stroke]?
        var objectsBefore: [any PageObject]?
        var objectsAfter: [any PageObject]?
        /// Strokes whose geometry the edit changes (a new thickness), so views drop their cached geometry.
        var reshaped: Set<UUID> = []
    }

    /// What `arrange(_:_:)` does. Ink is always drawn over objects, so strokes move among the ink and
    /// objects among the objects.
    enum Arrangement {
        case bringToFront, sendToBack
    }

    private(set) var strokes: [Stroke] = []
    /// Where the strokes and objects are, kept in step with them by every change below.
    private(set) var strokeIndex = StrokeIndex()
    private var undoStack: [Command] = []
    private var redoStack: [Command] = []
    /// The gesture each command on the stacks belongs to (`editGroup` when it was made), in step with them.
    private var undoGroups: [UUID?] = []
    private var redoGroups: [UUID?] = []

    /// While set, each new undoable edit is marked as part of this gesture. A stroke written across a page
    /// boundary in continuous scrolling is one piece per page, each an edit of its own page; they share a
    /// group so undo and redo (`InkNotebook.undoGroup(_:)`) take them all back in one step.
    var editGroup: UUID?

    /// The gesture the edit undo would take back belongs to, if it was marked with one.
    var undoGroup: UUID? {
        undoGroups.last ?? nil
    }

    /// The gesture the edit redo would put back belongs to, if it was marked with one.
    var redoGroup: UUID? {
        redoGroups.last ?? nil
    }

    /// What a change to the page was, for the views showing it.
    enum Change {
        /// Strokes were added, removed or moved, or the page was cleared; the undo state may have changed.
        case edited
        /// A late estimated-property update refined one committed stroke's points.
        case refined
        /// Only objects changed (added, removed, moved), not the ink; the undo state may have changed.
        case objectsEdited
    }

    /// A view showing the page. The same page can be on screen more than once (a note open in two
    /// windows), so every view showing it hears about each change, including those made by another view.
    private struct Observer {
        weak var owner: AnyObject?
        let onChange: (Change) -> Void
        let onPageSizeChange: () -> Void
        let onTemplateChange: () -> Void
    }

    private var observers: [Observer] = []

    /// Calls `onChange` after every edit, undo, redo and refinement of the page, `onPageSizeChange` after
    /// it's resized and `onTemplateChange` after its paper or background changes, until `owner` is released
    /// or `removeObserver(_:)` is called. Observing again with the same owner replaces its handlers.
    func addObserver(_ owner: AnyObject, onChange: @escaping (Change) -> Void,
                     onPageSizeChange: @escaping () -> Void = {},
                     onTemplateChange: @escaping () -> Void = {}) {
        removeObserver(owner)
        observers.append(Observer(owner: owner, onChange: onChange, onPageSizeChange: onPageSizeChange,
                                  onTemplateChange: onTemplateChange))
    }

    func removeObserver(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    /// Calls `onChange` after every change worth saving: each edit, undo, redo and refinement of the ink,
    /// and each change of size, template or background, until `owner` is released or
    /// `stopObservingChanges(_:)` is called. It's never called during a stroke, only once it's committed,
    /// so it's cheap to use for autosave. Observing again with the same owner replaces the handler.
    public func observeChanges(_ owner: AnyObject, onChange: @escaping () -> Void) {
        addObserver(owner, onChange: { _ in onChange() }, onPageSizeChange: onChange, onTemplateChange: onChange)
    }

    public func stopObservingChanges(_ owner: AnyObject) {
        removeObserver(owner)
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

    /// False while `setTemplate` changes the template and its artwork together, so observers redraw once.
    private var announcesTemplateChanges = true

    private func notifyTemplateChange() {
        guard announcesTemplateChanges else { return }
        for observer in liveObservers() {
            observer.onTemplateChange()
        }
    }

    /// Strokes whose points changed in place in the most recent change (transformed by the lasso, its undo
    /// or redo, or refined by a late estimate), so a view can invalidate their cached geometry.
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
        insertStroke(stroke, at: strokes.count)
        push(.add(stroke, splits: splits))
    }

    /// Removes strokes immediately (live erasing) without recording a command.
    /// Call `recordErase` once with everything removed during the gesture.
    func remove(ids: Set<UUID>) -> [Removal] {
        var removed: [Removal] = []
        for i in strokes.indices.reversed() where ids.contains(strokes[i].id) {
            removed.append(Removal(index: i, stroke: removeStroke(at: i)))
        }
        logInkChange()
        return removed
    }

    /// Removes the strokes at these positions immediately, like `remove(ids:)`, without looking at the
    /// others: for a caller that found them with `strokeIndices(in:)`.
    func remove(at positions: some Collection<Int>) -> [Removal] {
        defer { logInkChange() }
        return Set(positions).sorted(by: >).map { Removal(index: $0, stroke: removeStroke(at: $0)) }
    }

    func recordErase(_ removals: [Removal], objects objectRemovals: [ObjectRemoval] = []) {
        guard !removals.isEmpty || !objectRemovals.isEmpty else { return }
        push(.erase(removals, objects: objectRemovals))
    }

    /// Removes objects immediately without recording a command; pass them to `recordErase`.
    func removeObjects(ids: Set<UUID>) -> [ObjectRemoval] {
        var removed: [ObjectRemoval] = []
        for i in objects.indices.reversed() where ids.contains(objects[i].id) {
            removed.append(ObjectRemoval(index: i, object: removeObject(at: i)))
        }
        return removed
    }

    /// Deletes the selected strokes and objects as one undoable edit.
    func delete(_ selection: PageSelection) {
        recordErase(remove(ids: selection.strokeIDs), objects: removeObjects(ids: selection.objectIDs))
    }

    /// Puts `object` on the page above every other object, as one undoable edit. Its `zIndex` is set to
    /// the top of the stack.
    public func addObject(_ object: any PageObject) {
        var object = object
        object.zIndex = (objects.last?.zIndex ?? -1) + 1
        insertObject(object, at: objects.count)
        push(.addObject(object))
    }

    /// Shows these versions of objects (matched by id) in place, without recording a command or telling
    /// observers: a shape's handle being dragged. Follow with `replaceObjects(before:after:)`, or put
    /// the originals back with this.
    func previewObjects(_ changed: [any PageObject]) {
        place([], changed)
    }

    /// Replaces objects (matched by id) with changed versions of them, in place, as one undoable edit:
    /// a shape reshaped by a handle or restyled. `before` are the objects as they were.
    func replaceObjects(before: [any PageObject], after: [any PageObject]) {
        guard !after.isEmpty else { return }
        place([], after)
        push(.replaceObjects(before: before, after: after))
    }

    /// The object with this id, if it's on the page.
    public func object(id: UUID) -> (any PageObject)? {
        objects.first { $0.id == id }
    }

    /// Replaces a stroke, in place, with what's left of it after a standard erase (none if it's gone),
    /// without recording a command. Call `recordReplace(before:)` once at the end of the gesture with
    /// the strokes as they were when it began.
    func replace(id: UUID, with pieces: [Stroke]) {
        guard let i = strokes.firstIndex(where: { $0.id == id }) else { return }
        replaceStrokes(i ..< i + 1, with: pieces)
        logInkChange()
    }

    /// `replace(id:with:)` for the stroke at `position`, for a caller that found it with `strokeIndices(in:)`.
    /// Positions after it shift by `pieces.count - 1`.
    func replace(at position: Int, with pieces: [Stroke]) {
        replaceStrokes(position ..< position + 1, with: pieces)
        logInkChange()
    }

    /// Records the standard-erase gesture that changed `before` into the current strokes, as one command.
    func recordReplace(before: [Stroke]) {
        guard before.map(\.id) != strokes.map(\.id) else { return }
        push(.replace(before: before, after: strokes))
    }

    /// A transform in progress (dragging the selection or one of its handles): what's being transformed,
    /// as it was when the drag began.
    struct TransformSession {
        let strokes: [Stroke]
        let objects: [any PageObject]

        var selection: PageSelection {
            PageSelection(strokeIDs: Set(strokes.map(\.id)), objectIDs: Set(objects.map(\.id)))
        }
    }

    /// Starts transforming the selected strokes and objects (pixel-eraser strokes and objects of unknown
    /// kinds are left out). Follow with `previewTransform` while dragging and `commitTransform` or
    /// `cancelTransform` at the end.
    func beginTransform(_ selection: PageSelection) -> TransformSession {
        TransformSession(strokes: strokes.filter { selection.strokeIDs.contains($0.id) && !$0.brush.erases },
                         objects: objects.filter {
                             selection.objectIDs.contains($0.id) && PageObjectKinds.isSelectable($0)
                         })
    }

    /// Shows the session's strokes and objects transformed by `t` (from where they were when it began),
    /// without recording a command or telling observers: the view doing the drag redraws them itself.
    func previewTransform(_ session: TransformSession, by t: CGAffineTransform) {
        place(session.strokes.map { $0.applying(t) }, session.objects.map { $0.applying(t) })
        logInkChange()
    }

    /// Ends the session with `t` applied, as one undoable edit (none if `t` is the identity).
    func commitTransform(_ session: TransformSession, by t: CGAffineTransform) {
        guard !t.isIdentity, !session.strokes.isEmpty || !session.objects.isEmpty else {
            cancelTransform(session)
            return
        }
        let transformation = Transformation(transform: t, strokes: session.strokes, objects: session.objects)
        apply(transformation)
        push(.transform(transformation), reshaping: transformation.strokeIDs)
    }

    /// Ends the session with everything back where it was.
    func cancelTransform(_ session: TransformSession) {
        place(session.strokes, session.objects)
        logInkChange()
    }

    /// Transforms strokes and objects by `t` as one undoable edit.
    func transform(_ selection: PageSelection, by t: CGAffineTransform) {
        commitTransform(beginTransform(selection), by: t)
    }

    private func apply(_ transformation: Transformation) {
        place(transformation.strokes.map { $0.applying(transformation.transform) },
              transformation.objects.map { $0.applying(transformation.transform) })
    }

    /// Replaces strokes and objects with these versions of them (matched by id), in place.
    private func place(_ newStrokes: [Stroke], _ newObjects: [any PageObject]) {
        if !newStrokes.isEmpty {
            let byID = Dictionary(newStrokes.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for i in strokes.indices {
                if let replacement = byID[strokes[i].id] {
                    setStroke(replacement, at: i)
                }
            }
        }
        if !newObjects.isEmpty {
            let byID = Dictionary(newObjects.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for i in objects.indices {
                if let replacement = byID[objects[i].id] {
                    setObject(replacement, at: i)
                }
            }
        }
    }

    // MARK: Paste, duplicate, restyle, arrange

    /// Puts strokes and objects on the page (pasted or duplicated copies, with ids of their own) as one
    /// undoable edit: the strokes on top of the ink, the objects on top of the other objects, each in
    /// their own order.
    func insert(strokes newStrokes: [Stroke], objects newObjects: [any PageObject]) {
        guard !newStrokes.isEmpty || !newObjects.isEmpty else { return }
        var edit = Edit()
        if !newStrokes.isEmpty {
            edit.strokesBefore = strokes
            edit.strokesAfter = strokes + newStrokes
        }
        if !newObjects.isEmpty {
            var after = objects
            var z = (objects.last?.zIndex ?? -1) + 1
            for var object in PageObjectsFile.stacked(newObjects) {
                object.zIndex = z
                z += 1
                after.append(object)
            }
            edit.objectsBefore = objects
            edit.objectsAfter = after
        }
        commit(edit)
    }

    /// Changes the selected strokes and objects with `stroke` and `object` (a new colour or thickness) as
    /// one undoable edit. Pixel-eraser strokes and objects of unknown kinds are left alone. Strokes are
    /// recorded only if one of them changed.
    func restyle(_ selection: PageSelection, strokes restyleStroke: (Stroke) -> Stroke,
                 objects restyleObject: (any PageObject) -> any PageObject) {
        var edit = Edit()
        var after = strokes, reshaped = Set<UUID>()
        for i in after.indices where selection.strokeIDs.contains(after[i].id) && !after[i].brush.erases {
            let restyled = restyleStroke(after[i])
            guard restyled != after[i] else { continue }
            if restyled.brush != after[i].brush || restyled.points != after[i].points {
                reshaped.insert(restyled.id)
            }
            after[i] = restyled
        }
        if after != strokes {
            edit.strokesBefore = strokes
            edit.strokesAfter = after
            edit.reshaped = reshaped
        }
        let selected = objects.indices.filter {
            selection.objectIDs.contains(objects[$0].id) && PageObjectKinds.isSelectable(objects[$0])
        }
        if !selected.isEmpty {
            var afterObjects = objects
            for i in selected {
                afterObjects[i] = restyleObject(objects[i])
            }
            edit.objectsBefore = objects
            edit.objectsAfter = afterObjects
        }
        commit(edit)
    }

    /// Brings the selected strokes and objects to the front, or sends them to the back, keeping their own
    /// order, as one undoable edit (none if nothing moves). Objects are renumbered `0…` in their new order.
    func arrange(_ selection: PageSelection, _ arrangement: Arrangement) {
        func arranged<T>(_ items: [T], isSelected: (T) -> Bool) -> [T] {
            let chosen = items.filter(isSelected), others = items.filter { !isSelected($0) }
            return arrangement == .bringToFront ? others + chosen : chosen + others
        }
        var edit = Edit()
        let newStrokes = arranged(strokes) { selection.strokeIDs.contains($0.id) && !$0.brush.erases }
        if newStrokes.map(\.id) != strokes.map(\.id) {
            edit.strokesBefore = strokes
            edit.strokesAfter = newStrokes
        }
        var newObjects = arranged(objects) {
            selection.objectIDs.contains($0.id) && PageObjectKinds.isSelectable($0)
        }
        if newObjects.map(\.id) != objects.map(\.id) {
            for i in newObjects.indices {
                newObjects[i].zIndex = i
            }
            edit.objectsBefore = objects
            edit.objectsAfter = newObjects
        }
        commit(edit)
    }

    private func commit(_ edit: Edit) {
        guard edit.strokesAfter != nil || edit.objectsAfter != nil else { return }
        apply(edit, undoing: false)
        push(.edit(edit), reshaping: edit.reshaped)
    }

    private func apply(_ edit: Edit, undoing: Bool) {
        if let s = undoing ? edit.strokesBefore : edit.strokesAfter {
            setStrokes(s)
        }
        if let o = undoing ? edit.objectsBefore : edit.objectsAfter {
            setObjects(o)
        }
    }

    /// Removes every stroke and object, as one undoable edit.
    func clear() {
        guard !strokes.isEmpty || !objects.isEmpty else { return }
        let saved = strokes, savedObjects = objects
        setStrokes([])
        setObjects([])
        push(.clear(saved, objects: savedObjects))
    }

    /// Applies a late estimated-property update (force/tilt refinement) to a committed stroke.
    func updatePoint(strokeID: UUID, index: Int, _ body: (inout StrokePoint) -> Void) -> Bool {
        guard let s = strokes.lastIndex(where: { $0.id == strokeID }),
              strokes[s].points.indices.contains(index) else { return false }
        let location = strokes[s].points[index].location
        let reachBefore = strokeIndex.strokeBounds(at: s)
        body(&strokes[s].points[index])
        if strokes[s].points[index].location != location {
            strokeIndex.updateStroke(at: s, to: strokes[s])
        }
        noteInkChange(reachBefore.union(strokeIndex.strokeBounds(at: s)))
        revision += 1
        lastReshapedIDs = [strokeID]
        notify(.refined)
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let command = undoStack.popLast() else { return false }
        let group = undoGroups.popLast() ?? nil
        lastReshapedIDs = []
        switch command {
        case let .add(stroke, splits):
            if let i = strokes.lastIndex(where: { $0.id == stroke.id }) {
                redoStack.append(.add(removeStroke(at: i), splits: splits))
                revert(splits)
            }
        case let .erase(removals, objectRemovals):
            for r in removals.reversed() {
                insertStroke(r.stroke, at: min(r.index, strokes.count))
            }
            for r in objectRemovals.reversed() {
                insertObject(r.object, at: min(r.index, objects.count))
            }
            redoStack.append(command)
        case let .clear(saved, savedObjects):
            setStrokes(saved)
            setObjects(savedObjects)
            redoStack.append(command)
        case let .replace(before, _):
            setStrokes(before)
            redoStack.append(command)
        case let .transform(transformation):
            place(transformation.strokes, transformation.objects)
            lastReshapedIDs = transformation.strokeIDs
            redoStack.append(command)
        case let .addObject(object):
            setObjects(objects.filter { $0.id != object.id })
            redoStack.append(command)
        case let .edit(edit):
            apply(edit, undoing: true)
            lastReshapedIDs = edit.reshaped
            redoStack.append(command)
        case let .replaceObjects(before, _):
            place([], before)
            redoStack.append(command)
        }
        while redoGroups.count < redoStack.count {
            redoGroups.append(group)
        }
        announce(command)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let command = redoStack.popLast() else { return false }
        let group = redoGroups.popLast() ?? nil
        lastReshapedIDs = []
        switch command {
        case let .add(stroke, splits):
            apply(splits)
            insertStroke(stroke, at: strokes.count)
            undoStack.append(.add(stroke, splits: splits))
        case let .erase(removals, objectRemovals):
            let again = remove(ids: Set(removals.map(\.stroke.id)))
            let againObjects = removeObjects(ids: Set(objectRemovals.map(\.object.id)))
            undoStack.append(.erase(again, objects: againObjects))
        case .clear:
            undoStack.append(.clear(strokes, objects: objects))
            setStrokes([])
            setObjects([])
        case let .replace(_, after):
            setStrokes(after)
            undoStack.append(command)
        case let .transform(transformation):
            apply(transformation)
            lastReshapedIDs = transformation.strokeIDs
            undoStack.append(command)
        case let .addObject(object):
            setObjects(PageObjectsFile.stacked(objects + [object]))
            undoStack.append(command)
        case let .edit(edit):
            apply(edit, undoing: false)
            lastReshapedIDs = edit.reshaped
            undoStack.append(command)
        case let .replaceObjects(_, after):
            place([], after)
            undoStack.append(command)
        }
        while undoGroups.count < undoStack.count {
            undoGroups.append(group)
        }
        announce(command)
        return true
    }

    /// What a command changes: the ink, the objects or both.
    private func touches(_ command: Command) -> (ink: Bool, objects: Bool) {
        switch command {
        case .add, .replace: (true, false)
        case let .erase(removals, objectRemovals): (!removals.isEmpty, !objectRemovals.isEmpty)
        case let .clear(saved, savedObjects): (!saved.isEmpty, !savedObjects.isEmpty)
        case let .transform(t): (!t.strokes.isEmpty, !t.objects.isEmpty)
        case .addObject, .replaceObjects: (false, true)
        case let .edit(edit): (edit.strokesAfter != nil, edit.objectsAfter != nil)
        }
    }

    /// Bumps the revisions a command's undo or redo changed and tells the observers.
    private func announce(_ command: Command) {
        let changed = touches(command)
        bump(ink: changed.ink, objects: changed.objects)
    }

    private func bump(ink: Bool, objects changedObjects: Bool) {
        if changedObjects {
            objectsRevision += 1
        }
        if ink || !changedObjects {
            revision += 1
            notify(.edited)
        } else {
            notify(.objectsEdited)
        }
    }

    /// Highest index first, so replacing one stroke never shifts the index of another still to apply.
    private func apply(_ splits: [Split]) {
        for split in splits.sorted(by: { $0.index > $1.index }) {
            guard strokes.indices.contains(split.index), strokes[split.index].id == split.original.id else {
                assertionFailure("split target moved"); continue
            }
            replaceStrokes(split.index ..< split.index + 1, with: split.pieces)
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
            replaceStrokes(range, with: CollectionOfOne(split.original))
        }
    }

    // MARK: Whole-page operations

    /// A new page (with a new id) holding this page's size, template, background, objects and ink, with an
    /// empty undo history. It shares this page's cached committed layer, so it opens as quickly.
    public func copy() -> CanvasDocument {
        let page = CanvasDocument(pageSize: pageSize, template: template, templateArtwork: templateArtwork)
        page.strokes = strokes
        page.preservedRecords = preservedRecords
        page.objects = objects
        page.strokeIndex = strokeIndex
        page.revision = revision
        page.inkVersion = inkVersion
        page.inkChanges = InkChangeLog(version: inkVersion)
        page.objectsRevision = objectsRevision
        page.tileRaster = tileRaster
        return page
    }

    /// Turns the page a quarter turn, ink and objects and all, so a portrait page becomes landscape. The undo
    /// history is cleared: it describes the page the way it was.
    public func rotate(clockwise: Bool = true) {
        let width = pageSize.width, height = pageSize.height
        // Clockwise, the top-left corner goes to the top-right: (x, y) → (height − y, x).
        let t = clockwise
            ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
            : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        for i in strokes.indices {
            strokes[i] = strokes[i].applying(t)
        }
        for i in objects.indices where PageObjectKinds.isSelectable(objects[i]) {
            objects[i] = objects[i].applying(t)
        }
        strokeIndex = StrokeIndex(strokes: strokes, objects: objects)
        noteInkChange(nil)
        undoStack.removeAll()
        redoStack.removeAll()
        undoGroups.removeAll()
        redoGroups.removeAll()
        lastReshapedIDs = Set(strokes.map(\.id))
        revision += 1
        if !objects.isEmpty {
            objectsRevision += 1
        }
        pageSize = PageSize(width: height, height: width, name: pageSize.name)
        notify(.edited)
    }

    // MARK: Queries

    /// Positions in `strokes` of the strokes that may reach `rect` (page space), bottom first, from the
    /// page's `StrokeIndex`: a superset of those whose ink does, for the caller to check exactly.
    func strokeIndices(in rect: CGRect) -> [Int] {
        strokeIndex.strokes(in: rect)
    }

    /// The strokes that may reach `rect` (page space), bottom first (see `strokeIndices(in:)`).
    func strokes(in rect: CGRect) -> [Stroke] {
        strokeIndex.strokes(in: rect).map { strokes[$0] }
    }

    /// The objects whose bounds reach `rect` (page space), lowest first.
    func objects(in rect: CGRect) -> [any PageObject] {
        strokeIndex.objects(in: rect).map { objects[$0] }
    }

    // MARK: Changing strokes and objects (with the index in step)

    private func replaceStrokes(_ range: Range<Int>, with new: some Collection<Stroke>) {
        var changed = range.reduce(CGRect.null) { $0.union(strokeIndex.strokeBounds(at: $1)) }
        strokes.replaceSubrange(range, with: new)
        strokeIndex.replaceStrokes(range, with: new)
        for position in range.lowerBound ..< range.lowerBound + new.count {
            changed = changed.union(strokeIndex.strokeBounds(at: position))
        }
        noteInkChange(changed)
    }

    private func insertStroke(_ stroke: Stroke, at position: Int) {
        replaceStrokes(position ..< position, with: CollectionOfOne(stroke))
    }

    private func removeStroke(at position: Int) -> Stroke {
        let stroke = strokes[position]
        replaceStrokes(position ..< position + 1, with: EmptyCollection())
        return stroke
    }

    private func setStroke(_ stroke: Stroke, at position: Int) {
        let old = strokes[position]
        guard old != stroke else { return }
        let reachBefore = strokeIndex.strokeBounds(at: position)
        strokes[position] = stroke
        if !Self.sameReach(old, stroke) {
            strokeIndex.updateStroke(at: position, to: stroke)
        }
        noteInkChange(reachBefore.union(strokeIndex.strokeBounds(at: position)))
    }

    /// Replaces every stroke, refiling only those between the unchanged start and end of the page, so
    /// undoing an erase or a restyle costs the index about what the edit did.
    private func setStrokes(_ new: [Stroke]) {
        let old = strokes
        let shared = min(old.count, new.count)
        var prefix = 0
        while prefix < shared, Self.sameReach(old[prefix], new[prefix]) {
            prefix += 1
        }
        var suffix = 0
        while suffix < shared - prefix, Self.sameReach(old[old.count - 1 - suffix], new[new.count - 1 - suffix]) {
            suffix += 1
        }
        noteInkChange(InkChangeLog.changedReach(from: old, to: new))
        strokes = new
        strokeIndex.replaceStrokes(prefix ..< old.count - suffix, with: new[prefix ..< new.count - suffix])
    }

    /// Whether the index files `a` and `b` alike. Copy-on-write points compare by identity first, so an
    /// unchanged stroke costs next to nothing.
    private static func sameReach(_ a: Stroke, _ b: Stroke) -> Bool {
        a.points == b.points && a.brush == b.brush
    }

    private func insertObject(_ object: any PageObject, at position: Int) {
        objects.insert(object, at: position)
        strokeIndex.replaceObjects(position ..< position, with: CollectionOfOne(object))
    }

    private func removeObject(at position: Int) -> any PageObject {
        strokeIndex.replaceObjects(position ..< position + 1, with: EmptyCollection())
        return objects.remove(at: position)
    }

    private func setObject(_ object: any PageObject, at position: Int) {
        objects[position] = object
        strokeIndex.updateObject(at: position, to: object)
    }

    private func setObjects(_ new: [any PageObject]) {
        let old = objects
        let shared = min(old.count, new.count)
        var prefix = 0
        while prefix < shared, old[prefix].bounds == new[prefix].bounds {
            prefix += 1
        }
        var suffix = 0
        while suffix < shared - prefix, old[old.count - 1 - suffix].bounds == new[new.count - 1 - suffix].bounds {
            suffix += 1
        }
        objects = new
        strokeIndex.replaceObjects(prefix ..< old.count - suffix, with: new[prefix ..< new.count - suffix])
    }

    private func push(_ command: Command, reshaping reshaped: Set<UUID> = []) {
        undoStack.append(command)
        undoGroups.append(editGroup)
        redoStack.removeAll()
        redoGroups.removeAll()
        lastReshapedIDs = reshaped
        announce(command)
    }
}
