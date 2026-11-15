import UIKit

// MARK: - Writing across pages

/// A canvas embedded in continuous scrolling takes part in strokes carried across page boundaries
/// (`PageSeam`, `ContinuousCanvasView`): it begins them, joins those begun on other pages as they come
/// within reach, and undoes their other pages' parts with its own.
extension CanvasView {
    /// Undoes the page's latest edit. When it was part of a stroke or erase that crossed onto other pages
    /// in continuous scrolling, the other pages' parts are undone with it.
    @discardableResult
    func undo() -> Bool {
        endEditingText()
        let inkRevision = document.revision
        let group = document.undoGroup
        guard live == nil, lassoSession == nil, shapeSnap == nil, !isInkingOnAnyPage,
              editDocument({ document.undo() }) else { return false }
        if let group {
            editDocument {
                while document.undoGroup == group, document.undo() {}
            }
            controller?.continuousHost?.notebook.undoGroup(group)
        }
        redrawFromDocument(ink: document.revision != inkRevision)
        return true
    }

    /// Redoes the page's latest undone edit, with the other pages' parts of it (see `undo()`).
    @discardableResult
    func redo() -> Bool {
        endEditingText()
        let inkRevision = document.revision
        let group = document.redoGroup
        guard live == nil, lassoSession == nil, shapeSnap == nil, !isInkingOnAnyPage,
              editDocument({ document.redo() }) else { return false }
        if let group {
            editDocument {
                while document.redoGroup == group, document.redo() {}
            }
            controller?.continuousHost?.notebook.redoGroup(group)
        }
        redrawFromDocument(ink: document.revision != inkRevision)
        return true
    }

    /// True while a stroke in continuous scrolling is still being written, on this page or another: undo
    /// waits for it to end, since part of it may already be on a page.
    var isInkingOnAnyPage: Bool {
        isEmbedded && controller?.continuousHost?.isInking == true
    }

    /// Whether the stroke just begun can carry on onto the pages above and below in continuous scrolling:
    /// ink and the eraser. The shape tool, the lasso and the gesture tools stay on their page.
    var carriesAcrossPages: Bool {
        guard let tool = controller?.tool, tool.penKind != nil || tool == .eraser else { return false }
        return (live != nil && shapeSnap == nil) || eraseSession != nil
    }

    /// How far past the top and bottom of its page (canvas points) this page takes part in a stroke
    /// carried across pages: far enough that the ends of its piece, and their tapers, fall off the page,
    /// where they're clipped.
    var acrossPagesReach: CGFloat {
        if let brush = live?.stroke.brush {
            return PageSeam.reach(for: brush)
        }
        let radius = CGFloat(controller?.current.width ?? 0) / 2 / max(inputTransform.scale, 0.01)
        return PageSeam.reach(eraserRadius: radius)
    }

    /// Whether `touch` is within `reach` of this page, so its part of the stroke is drawn here.
    func reaches(_ touch: UITouch, within reach: CGFloat) -> Bool {
        PageSeam.reaches(viewTransform.toCanvas(touch.preciseLocation(in: self)), pageHeight: document.pageSize.height,
                         reach: reach)
    }

    /// The next event of a stroke this page joined; its touch arrives at the page that began it.
    func continueStroke(_ touch: UITouch, event: UIEvent?) {
        guard activeTouch === touch else { return }
        moveStroke(touch, event: event)
    }

    /// Whether a piece this page joined never reached the page itself, so there's nothing to keep.
    func isOffPage(_ live: LiveStroke) -> Bool {
        !PageSeam.inkReachesPage(live.stroke.points.map(\.location), pageBounds: document.pageBounds,
                                 inkRadius: PageSeam.inkRadius(of: live.stroke.brush))
    }

    /// Hands a stroke carried across pages on to the host after this page has handled the event: the
    /// page began it, so its touch keeps arriving here. `endingWith` says whether a stroke that ended is kept.
    func handOnAcrossPages(_ touches: Set<UITouch>, event: UIEvent?, endingWith commit: Bool? = nil) {
        guard isEmbedded, let host = controller?.continuousHost,
              let touch = touches.first(where: host.isWritingAcrossPages) else { return }
        if let commit {
            host.endWritingAcrossPages(touch, event: event, commit: commit, from: self)
        } else {
            host.writingAcrossPagesMoved(touch, event: event, from: self)
        }
    }
}
