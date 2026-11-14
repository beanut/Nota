import CoreGraphics
import Foundation

/// An action of the app's own in the lasso selection's menu, after InkKit's (cut, copy, colour, arrange…):
/// the hook for features that live outside InkKit, such as converting handwriting to text or AI actions.
///
/// ```swift
/// InkCanvasEditor(notebook: notebook, selectionActions: [
///     SelectionAction(id: "convert", title: "Convert to Text", systemImage: "character.cursor.ibeam") { selection in
///         recognizer.recognize(selection.ink)
///     }
/// ])
/// ```
public struct SelectionAction: Identifiable {
    public let id: String
    public var title: String
    /// An SF Symbol for the menu item, if any.
    public var systemImage: String?
    /// Whether the action is offered for this selection; by default it always is.
    public var isAvailable: (LassoSelection) -> Bool
    public var perform: (LassoSelection) -> Void

    public init(id: String, title: String, systemImage: String? = nil,
                isAvailable: @escaping (LassoSelection) -> Bool = { _ in true },
                perform: @escaping (LassoSelection) -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isAvailable = isAvailable
        self.perform = perform
    }
}

/// What the lasso has selected, as a `SelectionAction` sees it. A value: it doesn't change if the page does.
public struct LassoSelection {
    /// The page it's on (`CanvasDocument.id`).
    public let pageID: UUID
    /// The page-space bounds of the selected ink and objects.
    public let bounds: CGRect
    /// The selected ink in drawing order, as a `.ink` file of its own (with the page's id).
    public let ink: InkPageFile
    /// The selected objects, lowest `zIndex` first.
    public let objects: [any PageObject]

    init(pageID: UUID, strokes: [Stroke], objects: [any PageObject]) {
        let clip = SelectionClip(sourcePageID: pageID, strokes: strokes, objects: objects)
        self.pageID = pageID
        bounds = clip.bounds
        ink = InkPageFile(pageID: pageID, strokes: clip.strokes)
        self.objects = clip.objects
    }

    /// Number of selected strokes.
    public var strokeCount: Int {
        ink.strokeCount
    }

    /// The selection on its own, on a transparent background, at `scale` pixels per point.
    public func image(scale: CGFloat = 2) -> CGImage? {
        PageRenderer.image(strokes: ink.strokes, objects: objects, region: bounds.insetBy(dx: -2, dy: -2), scale: scale)
    }
}
