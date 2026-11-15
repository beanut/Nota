import UIKit
import UniformTypeIdentifiers

// MARK: - What the lasso can do with a selection

/// Cut, copy, paste and duplicate; recolour, thicken and thin; bring to front and send to back; take a
/// screenshot; drag out to other apps as an image. Each edit is one undo step (see `CanvasDocument.Edit`).
/// The selection's menu offers them (`UIEditMenuInteraction`), and so do the keyboard's ⌘X, ⌘C, ⌘V, ⌘D
/// and Delete.
extension CanvasView {
    /// How much Thinner and Thicker change a stroke's width each time.
    static let thicknessStep: CGFloat = 1.25

    /// The selected strokes in drawing order, without pixel-eraser strokes.
    var selectedStrokes: [Stroke] {
        document.strokes.filter { selection.strokeIDs.contains($0.id) && !$0.brush.erases }
    }

    /// The selected objects, lowest `zIndex` first, without objects of unknown kinds.
    var selectedObjects: [any PageObject] {
        document.objects.filter { selection.objectIDs.contains($0.id) && PageObjectKinds.isSelectable($0) }
    }

    /// The selection as a clip, ready for the pasteboard. Nil when nothing (visible) is selected.
    func selectionClip() -> SelectionClip? {
        let clip = SelectionClip(sourcePageID: document.id, strokes: selectedStrokes, objects: selectedObjects)
        return clip.isEmpty ? nil : clip
    }

    /// The selection on its own, transparent around it, at the screen's scale (at least 2×).
    func selectionImage(of clip: SelectionClip? = nil) -> UIImage? {
        guard let clip = clip ?? selectionClip() else { return nil }
        let scale = max(traitCollection.displayScale, 2)
        return PageRenderer.image(strokes: clip.strokes, objects: clip.objects,
                                  region: clip.bounds.insetBy(dx: -2, dy: -2), scale: scale)
            .map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
    }

    /// The part of the page visible on screen, in page space: where pastes and duplicates should land.
    var visiblePageRect: CGRect {
        var shown = bounds
        if let window {
            shown = shown.intersection(convert(window.bounds, from: window))
        }
        let visible = viewTransform.toCanvas(shown).intersection(document.pageBounds)
        return visible.isNull || visible.isEmpty ? document.pageBounds : visible
    }

    // MARK: Clipboard

    /// Puts the selection on the pasteboard: as a clip for Nota, and as a PNG for other apps.
    @discardableResult
    func copySelection() -> Bool {
        guard let controller, let clip = selectionClip(), let data = try? clip.encoded() else { return false }
        var item: [String: Any] = [SelectionClip.pasteboardType: data]
        if let png = selectionImage(of: clip)?.pngData() {
            item[UTType.png.identifier] = png
        }
        controller.pasteboard.setItems([item])
        controller.refreshCanPaste()
        return true
    }

    /// Copies the selection, then deletes it (one undo step: the delete).
    func cutSelection() {
        if copySelection() {
            deleteSelection()
        }
    }

    /// Pastes the pasteboard's clip onto this page and selects the copies: at `point` (canvas space) if
    /// given, otherwise where `PastePlacement` puts it. Without a clip, pastes the pasteboard's pictures
    /// instead (copied in another app). False if it has neither.
    @discardableResult
    func paste(at point: CGPoint? = nil) -> Bool {
        guard let controller,
              let data = controller.pasteboard.data(forPasteboardType: SelectionClip.pasteboardType),
              let clip = try? SelectionClip(data: data), !clip.isEmpty else {
            return pasteImages(at: point) // pictures copied in other apps
        }
        let onPage = Set(document.strokes.map(\.id)).union(document.objects.map(\.id))
        let originalsHere = !clip.originalIDs.isDisjoint(with: onPage)
        let earlier = pasteCounts[clip.id, default: 0]
        let offset = PastePlacement.offset(for: clip.bounds, visible: visiblePageRect,
                                           copiesInPlace: earlier + (originalsHere ? 1 : 0), at: point)
        if point == nil {
            pasteCounts[clip.id] = earlier + 1
        }
        return insertCopies(of: clip, offsetBy: offset)
    }

    /// Copies the selection a step down and to the right of itself, and selects the copies.
    func duplicateSelection() {
        guard let clip = selectionClip() else { return }
        insertCopies(of: clip, offsetBy: CGPoint(x: PastePlacement.step, y: PastePlacement.step))
    }

    @discardableResult
    func insertCopies(of clip: SelectionClip, offsetBy offset: CGPoint) -> Bool {
        guard let copies = try? clip.copies(offsetBy: offset) else { return false }
        // The copies are selected with the lasso, ready to move.
        if controller?.tool != .lasso {
            controller?.select(.lasso)
        }
        editDocument { document.insert(strokes: copies.strokes, objects: copies.objects) }
        redrawFromDocument(ink: !copies.strokes.isEmpty)
        select(PageSelection(strokeIDs: Set(copies.strokes.map(\.id)), objectIDs: Set(copies.objects.map(\.id))))
        showSelectionMenu()
        return true
    }

    // MARK: Style and order

    /// Recolours the selected ink and objects, as one undo step. Ink keeps its own opacity, so a
    /// highlighter stays see-through.
    func recolorSelection(_ color: PenColor) {
        let rgba = color.rgba
        restyleSelection(strokes: { stroke in
            var s = stroke
            s.color = RGBA(r: rgba.r, g: rgba.g, b: rgba.b, a: stroke.color.a)
            return s
        }, objects: { $0.recolored(color) })
    }

    /// Makes the selected ink `factor` times as thick (its widths and tapers), as one undo step.
    func scaleSelectionThickness(by factor: CGFloat) {
        restyleSelection(strokes: { stroke in
            var s = stroke
            s.brush = stroke.brush.scaled(by: factor)
            return s
        }, objects: { $0 })
    }

    /// Brings the selection to the front of its layer or sends it to the back, as one undo step.
    func arrangeSelection(_ arrangement: CanvasDocument.Arrangement) {
        guard !selection.isEmpty else { return }
        let inkRevision = document.revision
        editDocument { document.arrange(selection, arrangement) }
        redrawFromDocument(ink: document.revision != inkRevision)
    }

    func restyleSelection(strokes: (Stroke) -> Stroke, objects: (any PageObject) -> any PageObject) {
        guard !selection.isEmpty else { return }
        dropPending(selection.strokeIDs) // the full render draws them restyled
        let inkRevision = document.revision
        editDocument { document.restyle(selection, strokes: strokes, objects: objects) }
        redrawFromDocument(ink: document.revision != inkRevision)
    }

    /// The tool whose quick colours the selection's Color menu offers: the highlighter when only
    /// highlighter ink is selected, otherwise the pen.
    var selectionColorTool: Tool {
        let strokes = selectedStrokes
        let highlights = !strokes.isEmpty && selectedObjects.isEmpty && strokes.allSatisfy { $0.brush.blend == .multiply }
        return highlights ? .highlighter : .pen
    }

    /// The selection as an app's `SelectionAction` sees it.
    var lassoSelection: LassoSelection? {
        selection.isEmpty ? nil : LassoSelection(pageID: document.id, strokes: selectedStrokes, objects: selectedObjects)
    }

    // MARK: Screenshot

    /// Shares a picture of the page under the selection box, paper and all.
    func takeScreenshot() {
        guard let box = selectionBox, let image = screenshotImage(of: box) else { return }
        let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = self
        share.popoverPresentationController?.sourceRect = selectionViewRect(box)
        presenter?.present(share, animated: true)
    }

    func screenshotImage(of box: SelectionBox) -> UIImage? {
        let region = LassoGeometry.bounds(of: box.corners)
        let scale = max(traitCollection.displayScale, 2)
        let palette = paperTheme.palette(for: document.template.paper)
        return PageRenderer.image(of: document.snapshot(), region: region, scale: scale, palette: palette)
            .map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
    }

    private var presenter: UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// The selection box's bounding rectangle in view points.
    func selectionViewRect(_ box: SelectionBox) -> CGRect {
        LassoGeometry.bounds(of: box.corners.map { viewTransform.toView($0) })
    }

    // MARK: Menu

    func showSelectionMenu() {
        guard !selection.isEmpty, let box = selectionBox, window != nil, isActiveCanvas else { return }
        pendingPastePoint = nil
        let rect = selectionViewRect(box)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                               sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    /// Offers Paste where the lasso tapped (canvas space).
    func showPasteMenu(at point: CGPoint) {
        guard window != nil, isActiveCanvas else { return }
        pendingPastePoint = point
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: viewTransform.toView(point)))
    }

    func dismissEditMenu() {
        editMenu.dismissMenu()
    }

    @objc func handleLassoTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, controller?.tool == .lasso else { return }
        let point = viewTransform.toCanvas(g.location(in: self))
        if let box = selectionBox, !selection.isEmpty, box.contains(point, slop: Self.handleReach / viewTransform.scale) {
            showSelectionMenu()
        } else if !selection.isEmpty {
            clearSelection()
        } else if controller?.canPaste == true {
            showPasteMenu(at: point)
        }
    }

    /// The selection's menu, or Paste on its own after a tap on nothing.
    func editMenuElements() -> [UIMenuElement] {
        guard let controller else { return [] }
        if let point = pendingPastePoint {
            return [UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste(at: point)
            }]
        }
        guard !selection.isEmpty else { return [] }
        var edit: [UIMenuElement] = [
            UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.cutSelection() },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() }
        ]
        if controller.canPaste {
            edit.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste()
            })
        }
        edit.append(UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.duplicateSelection()
        })
        edit.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.deleteSelection()
        })

        let colorTool = selectionColorTool
        let colors = controller.quickColors(for: colorTool).map { color in
            UIAction(title: controller.colorName(color, for: colorTool), image: Self.swatch(color)) { [weak self] _ in
                self?.recolorSelection(color)
            }
        }
        var style: [UIMenuElement] = [UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"),
                                             options: .displayAsPalette, children: colors)]
        if !selectedStrokes.isEmpty {
            style.append(UIMenu(title: "Thickness", image: UIImage(systemName: "lineweight"), children: [
                UIAction(title: "Thicker", image: UIImage(systemName: "plus"), attributes: .keepsMenuPresented) { [weak self] _ in
                    self?.scaleSelectionThickness(by: Self.thicknessStep)
                },
                UIAction(title: "Thinner", image: UIImage(systemName: "minus"), attributes: .keepsMenuPresented) { [weak self] _ in
                    self?.scaleSelectionThickness(by: 1 / Self.thicknessStep)
                }
            ]))
        }
        style.append(UIMenu(title: "Arrange", image: UIImage(systemName: "square.3.layers.3d"), children: [
            UIAction(title: "Bring to Front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { [weak self] _ in
                self?.arrangeSelection(.bringToFront)
            },
            UIAction(title: "Send to Back", image: UIImage(systemName: "square.3.layers.3d.bottom.filled")) { [weak self] _ in
                self?.arrangeSelection(.sendToBack)
            }
        ]))
        style.append(contentsOf: imageMenuElements())
        style.append(contentsOf: linkMenuElements())
        style.append(UIAction(title: "Take Screenshot", image: UIImage(systemName: "camera.viewfinder")) { [weak self] _ in
            self?.takeScreenshot()
        })

        var menu: [UIMenuElement] = [UIMenu(options: .displayInline, children: edit),
                                     UIMenu(options: .displayInline, children: style)]
        if !controller.selectionActions.isEmpty, let lassoSelection {
            let extra = controller.selectionActions.filter { $0.isAvailable(lassoSelection) }.map { action in
                UIAction(title: action.title, image: action.systemImage.flatMap { UIImage(systemName: $0) }) { _ in
                    action.perform(lassoSelection)
                }
            }
            if !extra.isEmpty {
                menu.append(UIMenu(options: .displayInline, children: extra))
            }
        }
        return menu
    }

    private static func swatch(_ color: PenColor) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let rgba = color.rgba
            ctx.cgContext.setFillColor(rgba.cgColor())
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
        }.withRenderingMode(.alwaysOriginal)
    }

    // MARK: Keyboard

    /// The page the editor is working on: this one, or in continuous scrolling the current page.
    private var commandTarget: CanvasView {
        controller?.canvas ?? self
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let target = commandTarget
        let hasSelection = target.controller?.tool == .lasso && !target.selection.isEmpty
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)):
            return hasSelection
        case #selector(paste(_:)):
            return target.controller?.canPaste == true
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_: Any?) {
        commandTarget.copySelection()
    }

    override func cut(_: Any?) {
        commandTarget.cutSelection()
    }

    override func paste(_: Any?) {
        commandTarget.paste()
    }

    override func delete(_: Any?) {
        commandTarget.deleteSelection()
    }

    override func duplicate(_: Any?) {
        commandTarget.duplicateSelection()
    }
}

extension CanvasView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_: UIEditMenuInteraction, menuFor _: UIEditMenuConfiguration,
                             suggestedActions _: [UIMenuElement]) -> UIMenu? {
        let elements = editMenuElements()
        return elements.isEmpty ? nil : UIMenu(children: elements)
    }

    func editMenuInteraction(_: UIEditMenuInteraction, targetRectFor _: UIEditMenuConfiguration) -> CGRect {
        if let point = pendingPastePoint {
            let p = viewTransform.toView(point)
            return CGRect(x: p.x, y: p.y, width: 0, height: 0)
        }
        guard let box = selectionBox, !selection.isEmpty else { return .null }
        // Clear of the rotate knob above the box.
        return selectionViewRect(box).insetBy(dx: 0, dy: -(Self.rotateHandleDistance + Self.handleRadius))
    }
}

// MARK: - Dragging the selection out

extension CanvasView: UIDragInteractionDelegate {
    func dragInteraction(_: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard controller?.tool == .lasso, !selection.isEmpty, let box = selectionBox,
              box.contains(viewTransform.toCanvas(session.location(in: self)), slop: 0),
              let image = selectionImage() else { return [] }
        dismissEditMenu()
        let item = UIDragItem(itemProvider: NSItemProvider(object: image))
        item.localObject = image
        return [item]
    }

    func dragInteraction(_: UIDragInteraction, previewForLifting item: UIDragItem,
                         session _: UIDragSession) -> UITargetedDragPreview? {
        guard let image = item.localObject as? UIImage, let clip = selectionClip() else { return nil }
        // The image is in page points; on screen the page is zoomed.
        let rect = viewTransform.toView(clip.bounds.insetBy(dx: -2, dy: -2))
        let view = UIImageView(image: image)
        view.frame = CGRect(origin: .zero, size: rect.size)
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedDragPreview(view: view, parameters: parameters,
                                     target: UIDragPreviewTarget(container: self, center: CGPoint(x: rect.midX, y: rect.midY)))
    }
}
