import UIKit

extension Tool {
    /// Whether a tap with this tool on a link follows it. The lasso selects links instead (to change or
    /// remove them), the eraser never touches objects, and the text and tape tools' taps make text boxes and
    /// toggle tape.
    var followsLinks: Bool {
        switch self {
        case .pen, .pencil, .highlighter, .shape, .laser: true
        case .lasso, .eraser, .text, .tape: false
        }
    }
}

// MARK: - Links

/// Following links with a tap, and the selection menu's link items. A link is a page object (`LinkObject`)
/// drawn under the ink; adding one, pointing it elsewhere or removing it is one undoable edit.
extension CanvasView {
    /// The topmost link under `p` (canvas space), if any.
    func link(at p: CGPoint) -> LinkObject? {
        document.link(at: p, tolerance: 2 / max(viewTransform.scale, 1e-6))
    }

    /// Follows the topmost link under `p` (canvas space). False if there's no link there.
    @discardableResult
    func followLink(at p: CGPoint) -> Bool {
        guard let controller, let link = link(at: p) else { return false }
        if let target = link.target {
            feedback.alignmentOccurred(at: inputTransform.toView(p))
            controller.followLink(target, from: document.id)
        }
        return true
    }

    /// A tap on the page with `tool`: tape under it is revealed or hidden, and otherwise a link under it is
    /// followed. False if neither was there, so the tap is the tool's own.
    func tapObject(at p: CGPoint, tool: Tool?) -> Bool {
        guard let tool else { return false }
        if tool.togglesTape, toggleTape(at: p) {
            return true
        }
        return tool.followsLinks && followLink(at: p)
    }

    /// Whether a finger tap at `p` (canvas space) has tape or a link to act on with `tool`.
    func hasTapTarget(at p: CGPoint, tool: Tool) -> Bool {
        (tool.togglesTape && tape(at: p) != nil) || (tool.followsLinks && link(at: p) != nil)
    }

    // MARK: Selection menu

    /// The selected links.
    var selectedLinks: [LinkObject] {
        selectedObjects.compactMap { $0 as? LinkObject }
    }

    /// The selection menu's link items: Add Link… for anything that isn't a link; Open, Edit and Remove for
    /// a selected link.
    func linkMenuElements() -> [UIMenuElement] {
        let links = selectedLinks
        var items: [UIMenuElement] = []
        if links.count == 1, let link = links.first {
            if link.target != nil {
                items.append(UIAction(title: "Open Link", image: UIImage(systemName: "arrow.up.forward.square")) { [weak self] _ in
                    guard let self, let target = link.target else { return }
                    clearSelection()
                    controller?.followLink(target, from: document.id)
                })
            }
            items.append(UIAction(title: "Edit Link…", image: UIImage(systemName: "link")) { [weak self] _ in
                self?.requestLink(editing: link)
            })
        } else if links.isEmpty {
            items.append(UIAction(title: "Add Link…", image: UIImage(systemName: "link")) { [weak self] _ in
                self?.requestLink(editing: nil)
            })
        }
        if !links.isEmpty {
            items.append(UIAction(title: links.count == 1 ? "Remove Link" : "Remove Links",
                                  image: UIImage(systemName: "minus.circle"),
                                  attributes: .destructive) { [weak self] _ in
                    self?.removeSelectedLinks()
                })
        }
        return items
    }

    /// Asks the editor for a link target (`CanvasController.linkRequest`): for a new link over the selection,
    /// or to change `link`.
    func requestLink(editing link: LinkObject?) {
        let bounds: CGRect
        if let link {
            bounds = link.bounds
        } else {
            guard let selection = lassoSelection, !selection.bounds.isNull else { return }
            bounds = selection.bounds
        }
        controller?.requestLink(LinkRequest(pageID: document.id, bounds: bounds, linkID: link?.id, target: link?.target))
    }

    /// Puts the link the editor's sheet chose on the page, or points the link being edited there.
    func applyLink(_ request: LinkRequest, target: LinkTarget, title: String?) {
        guard request.pageID == document.id else { return }
        if let id = request.linkID {
            editDocument { _ = document.setLinkTarget(id: id, to: target, title: title) }
        } else {
            let color = controller.map { PenColor($0.theme.link) } ?? LinkObject.defaultColor
            editDocument { _ = document.addLink(to: target, covering: request.bounds, title: title, color: color) }
        }
        clearSelection()
        refreshObjects()
    }

    /// Removes the selected links, leaving what they covered, as one undoable edit.
    func removeSelectedLinks() {
        let ids = Set(selectedLinks.map(\.id))
        guard !ids.isEmpty else { return }
        editDocument { document.delete(PageSelection(objectIDs: ids)) }
        clearSelection()
        refreshObjects()
    }
}

/// The editor's link sheet is asked to choose where a link goes: for a new link over `bounds` on the page
/// `pageID`, or for the existing link `linkID` (currently going to `target`).
struct LinkRequest: Identifiable, Equatable {
    let id = UUID()
    let pageID: UUID
    let bounds: CGRect
    let linkID: UUID?
    let target: LinkTarget?
}
