import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// A PNG `width` × `height` pixels filled with a colour made from `seed`, so different seeds hash differently.
func makeImageData(width: Int = 400, height: Int = 300, seed: Int = 1) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
        UIColor(red: CGFloat(seed % 7) / 7, green: CGFloat(seed % 5) / 5, blue: CGFloat(seed % 3) / 3, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        UIColor.white.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    }
    return image.pngData()!
}

private func approximately(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.001) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

@Suite("Image objects")
struct ImageObjectTests {
    private let photo = ImageObject(asset: String(repeating: "a", count: 64), pixelSize: CGSize(width: 400, height: 300),
                                    frame: CGRect(x: 100, y: 100, width: 200, height: 150))

    private func roundTrip(_ object: any PageObject) throws -> (any PageObject)? {
        try PageObjectsFile(data: PageObjectsFile(pageID: UUID(), objects: [object]).encoded()).objects.first
    }

    @Test func aPictureRoundTripsWithItsCropMaskAndOpacity() throws {
        var image = photo.cropped(to: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        image.opacity = 0.5
        image.transform = CGAffineTransform(rotationAngle: 0.3)
        #expect(try roundTrip(image) as? ImageObject == image)

        let masked = photo.cropped(to: .zero, mask: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.5, y: 0.9)])
        #expect(try roundTrip(masked) as? ImageObject == masked)
        #expect(masked.mask?.count == 3)
    }

    @Test func aWholePictureWritesOnlyWhatItNeeds() throws {
        let data = try PageObjectsFile(pageID: UUID(), objects: [photo]).encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"kind\" : \"image\""))
        #expect(json.contains("\"asset\""))
        #expect(!json.contains("\"crop\""))
        #expect(!json.contains("\"mask\""))
        #expect(!json.contains("\"opacity\""))
    }

    @Test func readingIsLenient() throws {
        let json = """
        { "formatVersion": 1, "pageID": "\(UUID().uuidString)", "objects": [
          { "kind": "image", "id": "\(UUID().uuidString)", "frame": { "x": 0, "y": 0, "width": 50, "height": 40 },
            "pixelSize": [-1, 3], "crop": { "x": 0.5, "y": 0.5, "width": 0, "height": 2 },
            "mask": [[0, 0], [1, 1]], "opacity": 7 } ] }
        """
        let image = try #require(PageObjectsFile(data: Data(json.utf8)).objects.first as? ImageObject)
        #expect(image.asset.isEmpty) // drawn as a stand-in, not lost
        #expect(image.pixelSize == CGSize(width: 50, height: 40))
        #expect(image.crop == ImageObject.unitRect)
        #expect(image.mask == nil)
        #expect(image.opacity == 1)
    }

    @Test func croppingKeepsThePictureWhereItIs() {
        let crop = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let cropped = photo.cropped(to: crop)
        #expect(cropped.isCropped)
        #expect(approximately(cropped.imageRect, photo.imageRect))
        #expect(approximately(cropped.frame, CGRect(x: 150, y: 175, width: 100, height: 37.5)))
        // Cropping again works from the whole picture, and the whole picture comes back where it was.
        let again = cropped.cropped(to: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(approximately(again.frame, CGRect(x: 100, y: 100, width: 100, height: 75)))
        #expect(approximately(cropped.uncropped().frame, photo.frame))
        #expect(!cropped.uncropped().isCropped)
    }

    @Test func cropsStayInsideThePictureAndAboveTheMinimum() {
        let outside = photo.cropped(to: CGRect(x: -0.5, y: 0.9, width: 2, height: 0.5))
        #expect(approximately(outside.crop, CGRect(x: 0, y: 0.9, width: 1, height: 0.1)))
        let tiny = photo.cropped(to: CGRect(x: 0.5, y: 0.5, width: 0.0001, height: 0.0001))
        #expect(tiny.crop.width >= ImageObject.minimumCrop && tiny.crop.height >= ImageObject.minimumCrop)
    }

    @Test func aFreehandCropIsHitOnlyInsideItsOutline() {
        // A triangle: top-left, top-right, bottom-left of the picture.
        let masked = photo.cropped(to: .zero, mask: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)])
        #expect(approximately(masked.frame, photo.frame))
        #expect(masked.contains(CGPoint(x: 120, y: 120), tolerance: 0))
        #expect(!masked.contains(CGPoint(x: 290, y: 240), tolerance: 0)) // in the frame, outside the outline
        #expect(masked.contains(CGPoint(x: 200, y: 176), tolerance: 4)) // just off the diagonal edge
        // Through the protocol, as a tap's hit test calls it.
        let object: any PageObject = masked
        #expect(!object.contains(CGPoint(x: 290, y: 240), tolerance: 0))
        // A rotated picture is hit where it is on the page.
        var turned = photo
        turned.transform = CGAffineTransform(translationX: 200, y: 175).rotated(by: .pi / 2).translatedBy(x: -200, y: -175)
        #expect(turned.contains(CGPoint(x: 200, y: 260), tolerance: 0))
        #expect(!turned.contains(CGPoint(x: 290, y: 175), tolerance: 0))
    }

    @Test func movingAndResizingKeepTheCropAndOpacity() {
        var image = photo.cropped(to: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        image.opacity = 0.25
        let moved = image.applying(CGAffineTransform(scaleX: 2, y: 2))
        #expect(moved.crop == image.crop)
        #expect(moved.opacity == 0.25)
        #expect(approximately(moved.bounds, image.bounds.applying(CGAffineTransform(scaleX: 2, y: 2))))
        #expect(moved.recolored(PenColor(rgb: 0xFF0000)) == moved) // pictures have no colour of their own
    }

    @Test func opacityIsClamped() {
        var image = photo
        image.opacity = 0
        #expect(image.opacity == ImageObject.minimumOpacity)
        image.opacity = 3
        #expect(image.opacity == 1)
        #expect(ImageObject(asset: "x", pixelSize: CGSize(width: 1, height: 1), frame: .zero, opacity: -1).opacity
            == ImageObject.minimumOpacity)
    }

    @Test func aPageListsThePicturesItUsesEvenFromUnknownKinds() throws {
        let other = ImageObject(asset: String(repeating: "b", count: 64), pixelSize: CGSize(width: 10, height: 10),
                                frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let json = """
        { "formatVersion": 1, "pageID": "\(UUID().uuidString)", "objects": [
          { "kind": "collage", "id": "\(UUID().uuidString)", "frame": { "x": 0, "y": 0, "width": 5, "height": 5 },
            "asset": "\(String(repeating: "c", count: 64))" } ] }
        """
        var file = try PageObjectsFile(data: Data(json.utf8))
        file.objects += [photo, other, photo.cropped(to: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        #expect(file.imageAssetIDs == [photo.asset, other.asset, String(repeating: "c", count: 64)])
    }
}

@Suite("Image cropping geometry")
struct ImageCropGeometryTests {
    private let crop = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)

    @Test func dragsMoveOnlyTheirOwnSides() {
        let corner = ImageCropGeometry.dragging(ImageCropGeometry.Grip(x: 1, y: 1), of: crop, by: CGVector(dx: 0.1, dy: -0.1))
        #expect(approximately(corner, CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.4)))
        let edge = ImageCropGeometry.dragging(ImageCropGeometry.Grip(x: -1, y: 0), of: crop, by: CGVector(dx: -0.1, dy: 0.3))
        #expect(approximately(edge, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)))
    }

    @Test func dragsStopAtThePictureAndTheMinimumSize() {
        let past = ImageCropGeometry.dragging(ImageCropGeometry.Grip(x: -1, y: -1), of: crop, by: CGVector(dx: -1, dy: -1))
        #expect(approximately(past, CGRect(x: 0, y: 0, width: 0.7, height: 0.7)))
        let crossed = ImageCropGeometry.dragging(ImageCropGeometry.Grip(x: 1, y: 0), of: crop, by: CGVector(dx: -1, dy: 0))
        #expect(abs(crossed.width - ImageObject.minimumCrop) < 0.0001)
        let moved = ImageCropGeometry.dragging(.move, of: crop, by: CGVector(dx: 0.5, dy: -0.5))
        #expect(approximately(moved, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
    }

    @Test func aTinyOrBrokenOutlineIsNoMask() {
        #expect(ImageCropGeometry.mask(from: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.6)]) == nil)
        #expect(ImageCropGeometry.mask(from: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.501, y: 0.5), CGPoint(x: 0.5, y: 0.501)]) == nil)
        let outside = ImageCropGeometry.mask(from: [CGPoint(x: -1, y: 0.2), CGPoint(x: 0.5, y: 2), CGPoint(x: 0.9, y: 0.1)])
        #expect(outside == [CGPoint(x: 0, y: 0.2), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.9, y: 0.1)])
    }
}

@Suite("Image assets")
struct ImageAssetsTests {
    @Test func theSameBytesAreOneAssetAndNonImagesAreRefused() throws {
        let assets = ImageAssets()
        let data = makeImageData(seed: 11)
        let id = try #require(assets.add(data))
        #expect(id.count == 64)
        #expect(assets.add(data) == id)
        #expect(assets.add(makeImageData(seed: 12)) != id)
        #expect(assets.add(Data("not a picture".utf8)) == nil)
        #expect(assets.data(for: id) == data)
        #expect(ImageAssets.pixelSize(of: data) == CGSize(width: 400, height: 300))
        #expect(ImageAssets.fileExtension(of: data) == "png")
    }

    @Test func persistedAssetsAreReadFromTheirFile() throws {
        let assets = ImageAssets()
        let data = makeImageData(seed: 13)
        let id = try #require(assets.add(data))
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try data.write(to: url)
        assets.didPersist(id, at: url)
        #expect(assets.data(for: id) == data)
        try FileManager.default.removeItem(at: url)
        #expect(assets.data(for: id) == nil) // the memory copy went once it was on disk
        #expect(!ImageAssets().contains(id))
    }

    @Test func picturesAreDownsampledToTheSizeTheyreShownAt() throws {
        let assets = ImageAssets()
        let id = try #require(assets.add(makeImageData(width: 2000, height: 1000, seed: 14)))
        #expect(ImageAssets.bucket(for: 100, fullSize: 2000) == 256)
        #expect(ImageAssets.bucket(for: 600, fullSize: 2000) == 1024)
        #expect(ImageAssets.bucket(for: 1500, fullSize: 2000) == 0) // the whole picture
        let small = try #require(assets.image(for: id, pixelSize: 300, waits: true))
        #expect(max(small.width, small.height) == 512)
        let full = try #require(assets.image(for: id, pixelSize: 5000, waits: true))
        #expect(full.width == 2000 && full.height == 1000)
        // Without waiting, the nearest size already decoded stands in.
        let nearest = assets.image(for: id, pixelSize: 1000, waits: false)
        #expect(nearest != nil)
    }

    @Test func clipsCarryTheirPicturesBytes() throws {
        let source = ImageAssets(), target = ImageAssets()
        let data = makeImageData(seed: 15)
        let id = try #require(source.add(data))
        let image = ImageObject(asset: id, pixelSize: CGSize(width: 400, height: 300), frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        let clip = SelectionClip(sourcePageID: UUID(), strokes: [], objects: [image])
        let read = try SelectionClip(data: clip.encoded(assets: source), assets: target)
        #expect(read.objects.first as? ImageObject == image)
        #expect(target.data(for: id) == data)
    }

    @MainActor @Test func aPDFOfAPageWithAPictureHasThePicture() throws {
        let id = try #require(ImageAssets.shared.add(makeImageData(seed: 16)))
        let page = CanvasDocument(pageSize: .letter)
        page.addObject(ImageObject(asset: id, pixelSize: CGSize(width: 400, height: 300),
                                   frame: CGRect(x: 50, y: 50, width: 200, height: 150)))
        let pdf = try #require(PageRenderer.pdf(of: [page.snapshot()]) { .standard($0) })
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 1)
        #expect(pdf.count > 4000) // the picture's pixels are in it
    }
}
