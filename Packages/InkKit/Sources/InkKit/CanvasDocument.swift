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
            if committedRaster?.revision != revision {
                committedRaster = nil
            }
        }
    }

    /// The page's committed layer as the canvas last showed it, fitted, for reopening it without
    /// filling every stroke again. Dropped as soon as the page changes.
    var committedRaster: CommittedRaster?

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

    func recordErase(_ removals: [Removal], objects objectRemovals: [ObjectRemoval] = []) {
        guard !removals.isEmpty || !objectRemovals.isEmpty else { return }
        push(.erase(removals, objects: objectRemovals))
    }

    /// Removes objects immediately without recording a command; pass them to `recordErase`.
    func removeObjects(ids: Set<UUID>) -> [ObjectRemoval] {
        var removed: [ObjectRemoval] = []
        for i in objects.indices.reversed() where ids.contains(objects[i].id) {
            removed.append(ObjectRemoval(index: i, object: objects.remove(at: i)))
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
        objects.append(object)
        push(.addObject(object))
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
        strokes.replaceSubrange(i ... i, with: pieces)
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
                    strokes[i] = replacement
                }
            }
        }
        if !newObjects.isEmpty {
            let byID = Dictionary(newObjects.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for i in objects.indices {
                if let replacement = byID[objects[i].id] {
                    objects[i] = replacement
                }
            }
        }
    }

    /// Removes every stroke and object, as one undoable edit.
    func clear() {
        guard !strokes.isEmpty || !objects.isEmpty else { return }
        let saved = strokes, savedObjects = objects
        strokes.removeAll()
        objects.removeAll()
        push(.clear(saved, objects: savedObjects))
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
        case let .erase(removals, objectRemovals):
            for r in removals.reversed() {
                strokes.insert(r.stroke, at: min(r.index, strokes.count))
            }
            for r in objectRemovals.reversed() {
                objects.insert(r.object, at: min(r.index, objects.count))
            }
            redoStack.append(command)
        case let .clear(saved, savedObjects):
            strokes = saved
            objects = savedObjects
            redoStack.append(command)
        case let .replace(before, _):
            strokes = before
            redoStack.append(command)
        case let .transform(transformation):
            place(transformation.strokes, transformation.objects)
            lastReshapedIDs = transformation.strokeIDs
            redoStack.append(command)
        case let .addObject(object):
            objects.removeAll { $0.id == object.id }
            redoStack.append(command)
        }
        announce(command)
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
        case let .erase(removals, objectRemovals):
            let again = remove(ids: Set(removals.map(\.stroke.id)))
            let againObjects = removeObjects(ids: Set(objectRemovals.map(\.object.id)))
            undoStack.append(.erase(again, objects: againObjects))
        case .clear:
            undoStack.append(.clear(strokes, objects: objects))
            strokes.removeAll()
            objects.removeAll()
        case let .replace(_, after):
            strokes = after
            undoStack.append(command)
        case let .transform(transformation):
            apply(transformation)
            lastReshapedIDs = transformation.strokeIDs
            undoStack.append(command)
        case let .addObject(object):
            objects.append(object)
            objects = PageObjectsFile.stacked(objects)
            undoStack.append(command)
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
        case .addObject: (false, true)
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
        announce(command)
    }
}
