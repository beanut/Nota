import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// Pictures on a real `CanvasView`: inserting, pasting from another app, cropping (rectangle and freehand),
/// opacity, writing over them, and stickers saved from a selection and placed again.
@MainActor
@Suite("Canvas pictures")
struct CanvasImageTests {
    let pasteboard = UIPasteboard.withUniqueName()
    let stickerFolder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let controller: CanvasController
    let document = CanvasDocument(pageSize: .letter)
    let canvas: CanvasView

    init() throws {
        let suite = "CanvasImageTests.\(UUID().uuidString)"
        controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: suite)),
                                          penTray: PenTrayStore(fileURL: nil),
                                          stickers: StickerStore(folderURL: stickerFolder), pasteboard: pasteboard)
        canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
    }

    private var images: [ImageObject] {
        document.objects.compactMap { $0 as? ImageObject }
    }

    @Test func anInsertedPictureIsPlacedOnceAndSelected() throws {
        let data = makeImageData(width: 3000, height: 2000, seed: 21)
        controller.insertImages([data, data])
        #expect(images.count == 2)
        #expect(Set(images.map(\.asset)).count == 1) // stored once, placed twice
        #expect(controller.tool == .lasso)
        #expect(canvas.selection.objectIDs == Set(images.map(\.id)))
        let first = try #require(images.first)
        #expect(first.pixelSize == CGSize(width: 3000, height: 2000))
        // Fitted inside the page, keeping its shape.
        #expect(document.pageBounds.contains(first.bounds))
        #expect(abs(first.frame.width / first.frame.height - 1.5) < 0.001)
        // One undo step takes both away.
        canvas.undo()
        #expect(images.isEmpty)
        controller.insertImages([Data("nope".utf8)])
        #expect(images.isEmpty)
    }

    @Test func aPictureResizedFromACornerKeepsItsShape() throws {
        controller.insertImages([makeImageData(seed: 27)])
        let original = try #require(images.first)
        let box = try #require(canvas.selectionBox)
        // Drag the bottom-right corner much further right than down.
        let corner = CGPoint(x: box.rect.maxX, y: box.rect.maxY)
        canvas.lassoPending = true
        canvas.handleLassoSample(corner)
        canvas.handleLassoSample(CGPoint(x: corner.x + 120, y: corner.y + 10))
        canvas.finishLasso(commit: true)
        let resized = try #require(images.first)
        let before = original.bounds, after = resized.bounds
        #expect(after.width > before.width * 1.2)
        #expect(abs(after.width / after.height - before.width / before.height) < 0.001)
        #expect(after.minX == before.minX && after.minY == before.minY) // about the opposite corner

        // Shapes still stretch freely.
        let free = SelectionGeometry.transform(for: .corner(.bottomRight), box: box, from: corner,
                                               to: CGPoint(x: corner.x + 120, y: corner.y + 10))
        #expect(abs(free.a - free.d) > 0.1)
    }

    @Test func aPictureCopiedInAnotherAppIsPasted() {
        pasteboard.setItems([["public.png": makeImageData(seed: 22)]])
        controller.refreshCanPaste()
        #expect(controller.canPaste && controller.canPasteImages)
        #expect(canvas.paste())
        #expect(images.count == 1)
    }

    @Test func aDroppedPhotoIsCroppedAndWrittenOver() throws {
        controller.insertImages([makeImageData(seed: 23)])
        let original = try #require(images.first)
        canvas.beginImageCrop(.rectangle)
        let crop = try #require(canvas.imageCropView)
        #expect(controller.imageCrop == ImageCropState(mode: .rectangle, isCropped: false))
        #expect(!canvas.objectLayer.objects.contains { $0.id == original.id }) // the crop view shows it
        crop.drag(ImageCropGeometry.Grip(x: 1, y: 1), by: CGVector(dx: -0.5, dy: -0.5))
        #expect(controller.imageCrop?.isCropped == true)
        controller.finishImageCrop(commit: true)
        #expect(controller.imageCrop == nil)
        let cropped = try #require(images.first)
        #expect(abs(cropped.crop.width - 0.5) < 0.001)
        #expect(abs(cropped.frame.width - original.frame.width / 2) < 0.001)
        #expect(canvas.selection.objectIDs == [original.id]) // selected again

        // Ink goes over the picture, and the picture stays under it.
        document.add(makeStroke(at: CGPoint(x: cropped.frame.midX, y: cropped.frame.midY)))
        #expect(document.strokeCount == 1 && document.objectCount == 1)

        // Undo takes the crop back, then the ink, in order.
        canvas.undo()
        canvas.undo()
        #expect(images.first == original)
    }

    @Test func aFreehandCropAndCancelling() throws {
        controller.insertImages([makeImageData(seed: 24)])
        let original = try #require(images.first)
        canvas.beginImageCrop(.freehand)
        try #require(canvas.imageCropView).trace([CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.9)])
        controller.finishImageCrop(commit: false)
        #expect(images.first == original) // cancelled: nothing changed

        canvas.select(PageSelection(objectIDs: [original.id]))
        canvas.beginImageCrop(.freehand)
        try #require(canvas.imageCropView).trace([CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.9)])
        controller.finishImageCrop(commit: true)
        let masked = try #require(images.first)
        #expect(masked.mask?.count == 3)
        // The selection menu offers Reset Crop, which brings the whole picture back.
        canvas.select(PageSelection(objectIDs: [original.id]))
        canvas.resetSelectedImageCrop()
        #expect(images.first?.isCropped == false)
    }

    @Test func opacityIsOneUndoStep() {
        controller.insertImages([makeImageData(seed: 25)])
        canvas.setSelectionOpacity(0.5)
        #expect(images.first?.opacity == 0.5)
        let titles = canvas.editMenuElements().flatMap { ($0 as? UIMenu)?.children ?? [$0] }.map(Self.title)
        #expect(titles.contains("Opacity") && titles.contains("Crop") && titles.contains("Save as Sticker"))
        canvas.undo()
        #expect(images.first?.opacity == 1)
    }

    @Test func aLassoedDoodleIsSavedAndReusedAsASticker() throws {
        let stroke = makeStroke(at: CGPoint(x: 100, y: 100))
        document.add(stroke)
        controller.insertImages([makeImageData(seed: 26)])
        let picture = try #require(images.first)
        canvas.select(PageSelection(strokeIDs: [stroke.id], objectIDs: [picture.id]))
        #expect(canvas.saveSelectionAsSticker())
        let sticker = try #require(controller.stickers.stickers.first)
        #expect(sticker.name == "Sticker 1")
        #expect(UIImage(data: sticker.preview) != nil)

        // On another page (or in another note), it comes back as ink and a picture, centred in view.
        let other = CanvasDocument(pageSize: .letter)
        let otherCanvas = CanvasView(frame: canvas.frame, document: other)
        otherCanvas.controller = controller
        controller.canvas = otherCanvas
        otherCanvas.layoutIfNeeded()
        controller.insertSticker(sticker)
        #expect(other.strokeCount == 1)
        let placed = try #require(other.objects.first as? ImageObject)
        #expect(placed.asset == picture.asset && placed.id != picture.id)
        #expect(otherCanvas.selection.strokeIDs.count == 1 && otherCanvas.selection.objectIDs == [placed.id])
        let visible = otherCanvas.visiblePageRect
        let box = try #require(otherCanvas.selectionBox)
        #expect(abs(box.rect.midX - visible.midX) < 6 && abs(box.rect.midY - visible.midY) < 6)
    }

    private static func title(_ element: UIMenuElement) -> String {
        (element as? UIMenu)?.title ?? (element as? UIAction)?.title ?? ""
    }
}

@MainActor
@Suite("Sticker store")
struct StickerStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    private func clip(seed: Int) throws -> SelectionClip {
        let id = try #require(ImageAssets.shared.add(makeImageData(seed: seed)))
        let image = ImageObject(asset: id, pixelSize: CGSize(width: 400, height: 300), frame: CGRect(x: 0, y: 0, width: 40, height: 30))
        return SelectionClip(sourcePageID: UUID(), strokes: [makeStroke(at: CGPoint(x: 5, y: 5))], objects: [image])
    }

    @Test func stickersSurviveARelaunch() throws {
        let store = StickerStore(folderURL: folder)
        let first = try #require(store.add(clip(seed: 31), preview: Data([1, 2, 3])))
        let second = try #require(store.add(clip(seed: 32), preview: Data([4])))
        #expect(store.stickers.map(\.name) == ["Sticker 2", "Sticker 1"]) // newest first
        store.rename(first.id, to: "  Star  ")

        let reopened = StickerStore(folderURL: folder)
        #expect(reopened.stickers.map(\.id) == [second.id, first.id])
        #expect(reopened.stickers.map(\.name) == ["Sticker 2", "Star"])
        #expect(reopened.stickers[1].preview == Data([1, 2, 3]))
        let read = try reopened.stickers[1].selectionClip()
        #expect(read.strokes.count == 1)
        let expected = try clip(seed: 31).objects.first as? ImageObject
        #expect((read.objects.first as? ImageObject)?.asset == expected?.asset)
        #expect(store.lastSaveError == nil)

        reopened.delete(second.id)
        #expect(StickerStore(folderURL: folder).stickers.map(\.name) == ["Star"])
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "\(second.id.uuidString).clip").path))
    }

    @Test func aStickerCarriesItsPicturesBytes() throws {
        let data = makeImageData(seed: 33)
        let source = ImageAssets()
        let id = try #require(source.add(data))
        let image = ImageObject(asset: id, pixelSize: CGSize(width: 400, height: 300), frame: CGRect(x: 0, y: 0, width: 40, height: 30))
        let encoded = try SelectionClip(sourcePageID: UUID(), strokes: [], objects: [image]).encoded(assets: source)
        let target = ImageAssets()
        _ = try SelectionClip(data: encoded, assets: target)
        #expect(target.data(for: id) == data)
    }

    @Test func anUnreadableIndexIsSetAsideAndEmptySelectionsArentSaved() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appending(path: "Stickers.json"))
        let store = StickerStore(folderURL: folder)
        #expect(store.stickers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Stickers.unreadable.json").path))
        #expect(store.add(SelectionClip(sourcePageID: UUID(), strokes: [], objects: []), preview: Data()) == nil)
        #expect(StickerStore(folderURL: nil).stickers.isEmpty)
    }
}
