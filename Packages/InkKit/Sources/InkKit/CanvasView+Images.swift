import UIKit
import UniformTypeIdentifiers

// MARK: - Pictures on the page

/// Putting pictures on the page (from Photos, the camera, Files, the pasteboard or a drop), cropping them
/// (`ImageCropView`), their opacity, and stickers. Each edit is one undo step. Pictures are drawn by the
/// object layer, never on the ink path.
extension CanvasView {
    /// How much of the visible page's shorter side a new picture may take at most.
    static let insertedImageFraction: CGFloat = 0.6

    /// Puts pictures (image file bytes) on the page and selects them with the lasso: centred on `point`
    /// (canvas space), or on the visible part of the page, each further one a step along. Bytes that aren't
    /// a picture are skipped. Returns the pictures placed.
    @discardableResult
    func insertImages(_ items: [Data], at point: CGPoint? = nil) -> [ImageObject] {
        let visible = visiblePageRect
        let page = document.pageBounds
        var center = point ?? CGPoint(x: visible.midX, y: visible.midY)
        center = CGPoint(x: min(max(center.x, page.minX), page.maxX), y: min(max(center.y, page.minY), page.maxY))
        var images: [ImageObject] = []
        for data in items {
            guard let id = ImageAssets.shared.add(data), let size = ImageAssets.pixelSize(of: data) else { continue }
            let step = PastePlacement.step * CGFloat(images.count)
            let frame = Self.imageFrame(pixelSize: size, centeredAt: CGPoint(x: center.x + step, y: center.y + step),
                                        visible: visible)
            images.append(ImageObject(asset: id, pixelSize: size, frame: frame))
        }
        guard !images.isEmpty else { return [] }
        endEditingText()
        finishImageCrop(commit: true)
        if isEmbedded {
            controller?.embeddedCanvasWillInk(self)
        }
        // The pictures are selected with the lasso, ready to move, resize, crop or write over.
        if controller?.tool != .lasso {
            controller?.select(.lasso)
        }
        editDocument { document.insert(strokes: [], objects: images) }
        refreshObjects()
        select(PageSelection(objectIDs: Set(images.map(\.id))))
        showSelectionMenu()
        return images
    }

    /// A new picture's frame: a pixel per half point (a 2× screen's), shrunk to fit
    /// `insertedImageFraction` of the visible page, centred on `center`.
    static func imageFrame(pixelSize: CGSize, centeredAt center: CGPoint, visible: CGRect) -> CGRect {
        let natural = CGSize(width: max(pixelSize.width, 1) / 2, height: max(pixelSize.height, 1) / 2)
        let limit = max(min(visible.width, visible.height) * insertedImageFraction, 40)
        let scale = min(1, limit / max(natural.width, natural.height))
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The pictures on the pasteboard (copied in another app), as image file bytes: each item's original
    /// file where it has one, otherwise its image re-encoded.
    func pasteboardImages() -> [Data] {
        guard let pasteboard = controller?.pasteboard, pasteboard.hasImages else { return [] }
        let preferred = [UTType.heic, .jpeg, .png, .tiff, .gif].map(\.identifier)
        return pasteboard.items.compactMap { item in
            let types = item.keys.filter { UTType($0)?.conforms(to: .image) == true }
                .sorted { (preferred.firstIndex(of: $0) ?? 99, $0) < (preferred.firstIndex(of: $1) ?? 99, $1) }
            for type in types {
                if let data = item[type] as? Data, ImageAssets.pixelSize(of: data) != nil {
                    return data
                }
                if let image = item[type] as? UIImage {
                    return Self.fileData(for: image)
                }
            }
            return nil
        }
    }

    /// Pastes the pasteboard's pictures onto the page. False if it has none.
    @discardableResult
    func pasteImages(at point: CGPoint? = nil) -> Bool {
        let images = pasteboardImages()
        return !images.isEmpty && !insertImages(images, at: point).isEmpty
    }

    /// A photo's bytes for storing: JPEG, or PNG for a picture with transparency.
    static func fileData(for image: UIImage) -> Data? {
        let alpha = image.cgImage?.alphaInfo
        let opaque = alpha == nil || alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst
        return opaque ? image.jpegData(compressionQuality: 0.9) : image.pngData()
    }

    // MARK: Selected pictures

    /// The selected pictures, lowest first.
    var selectedImages: [ImageObject] {
        selectedObjects.compactMap { $0 as? ImageObject }
    }

    /// The one selected picture, when a picture and nothing else is selected.
    var selectedImage: ImageObject? {
        let images = selectedImages
        return images.count == 1 && selection.strokeIDs.isEmpty && selection.objectIDs.count == 1 ? images[0] : nil
    }

    /// Sets the selected pictures' opacity (0.05…1), as one undo step.
    func setSelectionOpacity(_ opacity: CGFloat) {
        guard !selectedImages.isEmpty else { return }
        restyleSelection(strokes: { $0 }, objects: { object in
            guard var image = object as? ImageObject else { return object }
            image.opacity = opacity
            return image
        })
    }

    /// Shows the whole of the selected picture again, as one undo step.
    func resetSelectedImageCrop() {
        guard let image = selectedImage, image.isCropped else { return }
        let whole = image.uncropped()
        editDocument { document.replaceObjects(before: [image], after: [whole]) }
        refreshObjects()
        updateSelectionBox()
    }

    // MARK: Cropping

    /// Starts cropping the selected picture. The crop bar finishes it (`finishImageCrop`).
    func beginImageCrop(_ mode: ImageCropMode) {
        guard let image = selectedImage else { return }
        finishImageCrop(commit: true)
        dismissEditMenu()
        clearSelection()
        let view = ImageCropView(image: image, mode: mode, accent: accentColor,
                                 knobFill: paperColor.resolvedColor(with: InkTheme.onPaper))
        view.onChange = { [weak self] in self?.imageCropDidChange() }
        imageCropView = view
        addSubview(view)
        placeImageCrop()
        refreshObjects()
        imageCropDidChange()
    }

    /// Keeps the crop over its picture as the canvas lays out.
    func placeImageCrop() {
        guard let view = imageCropView else { return }
        view.frame = bounds
        view.place(at: viewTransform, screenScale: window?.screen.scale ?? traitCollection.displayScale)
    }

    /// Ends cropping: with `commit`, the picture keeps the new crop (one undo step); otherwise it's left as
    /// it was. The picture is selected again either way.
    func finishImageCrop(commit: Bool) {
        guard let view = imageCropView else { return }
        imageCropView = nil
        view.onChange = nil
        view.removeFromSuperview()
        let result = view.result
        if commit, result != view.original, document.object(id: view.original.id) != nil {
            editDocument { document.replaceObjects(before: [view.original], after: [result]) }
        }
        refreshObjects()
        controller?.imageCropDidChange(nil)
        if controller?.tool == .lasso, document.object(id: view.original.id) != nil {
            select(PageSelection(objectIDs: [view.original.id]))
        }
    }

    func setImageCropMode(_ mode: ImageCropMode) {
        imageCropView?.setMode(mode)
    }

    func resetImageCrop() {
        imageCropView?.reset()
    }

    private func imageCropDidChange() {
        controller?.imageCropDidChange(imageCropView?.state)
    }

    /// Whether the touch landed on the picture being cropped (it takes every touch while it's up).
    func isInImageCrop(_ touch: UITouch) -> Bool {
        guard let crop = imageCropView, let view = touch.view else { return false }
        return view.isDescendant(of: crop)
    }

    // MARK: Stickers

    /// Saves the selection (ink, shapes, text and pictures) to the sticker collection. False if nothing is
    /// selected or it can't be drawn.
    @discardableResult
    func saveSelectionAsSticker() -> Bool {
        guard let store = controller?.stickers, let clip = selectionClip(), let png = selectionImage(of: clip)?.pngData(),
              store.add(clip, preview: png) != nil else { return false }
        if let box = selectionBox {
            feedback.alignmentOccurred(at: viewTransform.toView(CGPoint(x: box.rect.midX, y: box.rect.midY)))
        }
        return true
    }

    /// Places a copy of `sticker` in the middle of the visible part of the page and selects it.
    @discardableResult
    func insertSticker(_ sticker: Sticker) -> Bool {
        guard let clip = try? sticker.selectionClip(), !clip.isEmpty else { return false }
        endEditingText()
        finishImageCrop(commit: true)
        let visible = visiblePageRect
        let offset = PastePlacement.offset(for: clip.bounds, visible: visible, copiesInPlace: 0,
                                           at: CGPoint(x: visible.midX, y: visible.midY))
        return insertCopies(of: clip, offsetBy: offset)
    }

    // MARK: Menu

    /// The selection menu's picture items: Crop (for one picture), Opacity (for any) and Save as Sticker.
    func imageMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if let image = selectedImage {
            var crop: [UIMenuElement] = [
                UIAction(title: "Crop", image: UIImage(systemName: "crop")) { [weak self] _ in
                    self?.beginImageCrop(.rectangle)
                },
                UIAction(title: "Freehand Crop", image: UIImage(systemName: "lasso")) { [weak self] _ in
                    self?.beginImageCrop(.freehand)
                }
            ]
            if image.isCropped {
                crop.append(UIAction(title: "Reset Crop", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
                    self?.resetSelectedImageCrop()
                })
            }
            elements.append(UIMenu(title: "Crop", image: UIImage(systemName: "crop"), children: crop))
        }
        let images = selectedImages
        if !images.isEmpty {
            let current = images.count == 1 ? images[0].opacity : nil
            let levels: [CGFloat] = [1, 0.75, 0.5, 0.25]
            let choices = levels.map { level in
                let isCurrent = current.map { abs($0 - level) < 0.01 } == true
                return UIAction(title: "\(Int(level * 100))%", state: isCurrent ? .on : .off) { [weak self] _ in
                    self?.setSelectionOpacity(level)
                }
            }
            elements.append(UIMenu(title: "Opacity", image: UIImage(systemName: "circle.lefthalf.filled"), children: choices))
        }
        if controller?.stickers != nil {
            elements.append(UIAction(title: "Save as Sticker", image: UIImage(systemName: "star.square.on.square")) { [weak self] _ in
                self?.saveSelectionAsSticker()
            })
        }
        return elements
    }
}

// MARK: - Dropping pictures

extension CanvasView: UIDropInteractionDelegate {
    func installImageDrop() {
        addInteraction(UIDropInteraction(delegate: self))
    }

    func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        // A selection dragged out of this app is ink, not a photo to place.
        session.localDragSession == nil && session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
    }

    func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
        let point = viewTransform.toCanvas(session.location(in: self))
        let providers = session.items.map(\.itemProvider)
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        Self.loadImages(from: providers) { [weak self] images in
            self?.insertImages(images, at: point)
        }
    }

    /// Loads each provider's picture as image file bytes, in order, then calls `completion` on the main
    /// actor with those that loaded.
    static func loadImages(from providers: [NSItemProvider], completion: @escaping @MainActor ([Data]) -> Void) {
        var results = [Data?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, provider) in providers.enumerated() {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                DispatchQueue.main.async {
                    results[i] = data
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(results.compactMap { $0 }) }
        }
    }
}
