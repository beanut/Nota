import CoreGraphics
import Foundation

/// A copied lasso selection: strokes and objects as they were on the page they came from, ready to paste
/// onto any page of any note. It travels through the system pasteboard as `pasteboardType`, next to a PNG
/// of the selection for other apps, so it reaches other pages, other notes and other windows alike.
///
/// Encoded as JSON, with the ink and objects in their own file formats so a clip reads exactly what a page
/// would:
///
/// ```json
/// { "formatVersion": 1, "id": "…", "sourcePageID": "…",
///   "ink": "<base64 .ink file>", "objects": "<base64 objects file, or absent>" }
/// ```
///
/// A clip from a newer format version, or one that doesn't decode, isn't pasted
/// (`SelectionClipError`). Objects of kinds this version doesn't know are dropped: they can't be drawn or
/// selected, so a pasted copy of one would be invisible and stuck.
struct SelectionClip {
    /// The pasteboard type the clip is written as.
    static let pasteboardType = "app.nota.inkkit.selection"
    static let formatVersion = 1

    /// Identifies one copy, so pasting the same clip on the same page again lands a step further along.
    let id: UUID
    /// The page the selection was copied from (`CanvasDocument.id`).
    let sourcePageID: UUID
    /// In drawing order. Pixel-eraser strokes are never copied: they're invisible on their own.
    let strokes: [Stroke]
    /// Lowest `zIndex` first.
    let objects: [any PageObject]
    /// The page-space bounds of the drawn ink and the objects.
    let bounds: CGRect

    init(id: UUID = UUID(), sourcePageID: UUID, strokes: [Stroke], objects: [any PageObject]) {
        self.id = id
        self.sourcePageID = sourcePageID
        self.strokes = strokes.filter { !$0.brush.erases }
        self.objects = PageObjectsFile.stacked(objects.filter(PageObjectKinds.isSelectable))
        var r = CGRect.null
        for stroke in self.strokes {
            r = r.union(StrokeRenderer.geometry(for: stroke).bounds)
        }
        for object in self.objects {
            r = r.union(object.bounds)
        }
        bounds = r
    }

    var isEmpty: Bool {
        strokes.isEmpty && objects.isEmpty
    }

    /// The ids of what was copied, to tell whether the originals are still on a page.
    var originalIDs: Set<UUID> {
        Set(strokes.map(\.id)).union(objects.map(\.id))
    }

    // MARK: Coding

    private struct Envelope: Codable {
        var formatVersion: Int
        var id: UUID
        var sourcePageID: UUID
        var ink: Data
        var objects: Data?
    }

    func encoded() throws -> Data {
        let ink = InkPageFile(pageID: sourcePageID, strokes: strokes).encoded()
        let objectsData = objects.isEmpty ? nil : try PageObjectsFile(pageID: sourcePageID, objects: objects).encoded()
        return try JSONEncoder().encode(Envelope(formatVersion: Self.formatVersion, id: id, sourcePageID: sourcePageID,
                                                 ink: ink, objects: objectsData))
    }

    init(data: Data) throws {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SelectionClipError.notAClip
        }
        guard envelope.formatVersion >= 1 else { throw SelectionClipError.notAClip }
        guard envelope.formatVersion <= Self.formatVersion else {
            throw SelectionClipError.unsupportedVersion(envelope.formatVersion)
        }
        do {
            let strokes = try InkPageFile(data: envelope.ink).strokes
            let objects = try envelope.objects.map { try PageObjectsFile(data: $0).objects } ?? []
            self.init(id: envelope.id, sourcePageID: envelope.sourcePageID, strokes: strokes, objects: objects)
        } catch {
            throw SelectionClipError.corrupt(String(describing: error))
        }
    }

    // MARK: Pasting

    /// Fresh copies of everything in the clip, moved by `offset`: every stroke and object gets a new id, so
    /// the copies can sit on the same page as the originals (and as each other).
    func copies(offsetBy offset: CGPoint) throws -> (strokes: [Stroke], objects: [any PageObject]) {
        let t = CGAffineTransform(translationX: offset.x, y: offset.y)
        let strokes = strokes.map { stroke in
            var copy = Stroke(id: UUID(), color: stroke.color, brush: stroke.brush, points: stroke.points)
            copy.createdAt = stroke.createdAt
            return t.isIdentity ? copy : copy.applying(t)
        }
        let objects = try PageObjectsFile.copies(of: objects).map { t.isIdentity ? $0 : $0.applying(t) }
        return (strokes, objects)
    }
}

enum SelectionClipError: Error, Equatable {
    /// Not JSON in the clip's shape.
    case notAClip
    /// Written by a newer version of the app.
    case unsupportedVersion(Int)
    /// The envelope is fine but the ink or objects inside it aren't.
    case corrupt(String)
}

/// Where a pasted clip goes on a page.
enum PastePlacement {
    /// How far each repeated paste moves along, in page points.
    static let step: CGFloat = 24

    /// The offset to paste a clip whose content has `bounds` with, on a page whose visible part is
    /// `visible` (page space):
    ///
    /// - At `point` (a paste where the lasso tapped): centred on it.
    /// - Otherwise in the clip's own place, so a selection cut from one page or note and pasted on another
    ///   keeps its position; one step along for each copy already in that place (the originals still on
    ///   the page count as one, and so does each earlier paste of the same clip on it).
    /// - If that place isn't wholly in view, centred in the visible part of the page instead.
    static func offset(for bounds: CGRect, visible: CGRect, copiesInPlace: Int, at point: CGPoint? = nil) -> CGPoint {
        guard !bounds.isNull, !bounds.isInfinite else { return .zero }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let point {
            return CGPoint(x: point.x - center.x, y: point.y - center.y)
        }
        let nudge = step * CGFloat(max(copiesInPlace, 0))
        if visible.contains(bounds.offsetBy(dx: nudge, dy: nudge)) {
            return CGPoint(x: nudge, y: nudge)
        }
        return CGPoint(x: visible.midX - center.x, y: visible.midY - center.y)
    }
}
