import Compression
import CoreGraphics
import Foundation

/// A page's committed layer as the canvas last showed it fitted, compressed, so reopening the page puts
/// the same pixels back instead of filling every stroke again (Architecture §6: page open under 150 ms).
///
/// A full render of a 5k-stroke page is seconds of Core Graphics fills even spread over every core;
/// restoring this is a ~15 ms decompression straight into the new bitmap. It's lossless, so the reopened
/// page is pixel for pixel what was on screen.
///
/// The raster is only good for the page's `revision` it was taken at and for the exact bitmap it came
/// from: the same pixel size, display scale and fitted transform. Anything else (a rotation, new margins,
/// an edit made elsewhere) falls back to a full render. LZFSE keeps a dense 5k-stroke page around 5 MB.
struct CommittedRaster: @unchecked Sendable {
    /// The page's `CanvasDocument.revision` that the pixels show.
    let revision: Int
    /// The transform the strokes were drawn at.
    let transform: ViewTransform
    let pixelWidth: Int
    let pixelHeight: Int
    let bytesPerRow: Int
    let scale: CGFloat
    /// LZFSE-compressed bitmap bytes, `bytesPerRow × pixelHeight` of them.
    let compressed: Data

    /// Compresses `image`, a snapshot of a bitmap from `CommittedRenderer.makeBitmap`. Slow (~200 ms for a
    /// full iPad screen): run it off the main thread. Nil if `image` isn't laid out like that bitmap.
    init?(image: CGImage, revision: Int, transform: ViewTransform, scale: CGFloat) {
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              image.bitmapInfo.rawValue == CommittedRenderer.bitmapInfo,
              let bytes = image.dataProvider?.data
        else { return nil }
        let length = image.bytesPerRow * image.height
        guard CFDataGetLength(bytes) >= length else { return nil }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { destination.deallocate() }
        let size = compression_encode_buffer(destination, length, CFDataGetBytePtr(bytes), length, nil,
                                             COMPRESSION_LZFSE)
        // 0: it didn't fit in the raw size, which ink never comes near; storing it raw isn't worth it.
        guard size > 0 else { return nil }
        self.revision = revision
        self.transform = transform
        pixelWidth = image.width
        pixelHeight = image.height
        bytesPerRow = image.bytesPerRow
        self.scale = scale
        compressed = Data(bytes: destination, count: size)
    }

    /// Renders `items` into a new bitmap of `pixelSize` at `transform` and compresses that: for a page
    /// whose committed layer isn't on screen as it is now. Seconds for a dense page; run it in the background.
    init?(rendering items: [CommittedRenderer.Item], pixelSize: CGSize, scale: CGFloat, transform: ViewTransform,
          revision: Int) {
        guard let ctx = CommittedRenderer.makeBitmap(pixelSize: pixelSize, scale: scale) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: pixelSize.width / scale, height: pixelSize.height / scale)
        CommittedRenderer.render(items, into: ctx, bounds: bounds, transform: transform)
        guard let image = ctx.makeImage() else { return nil }
        self.init(image: image, revision: revision, transform: transform, scale: scale)
    }

    /// Whether this raster can stand in for a full render of a page at `revision` into a bitmap of
    /// `pixelSize` at `scale`, drawn at `transform`.
    func matches(revision: Int, pixelSize: CGSize, scale: CGFloat, transform: ViewTransform) -> Bool {
        self.revision == revision && self.transform == transform && self.scale == scale
            && CGFloat(pixelWidth) == pixelSize.width && CGFloat(pixelHeight) == pixelSize.height
    }

    /// Decompresses the pixels straight into `ctx`, replacing everything in it. `ctx` must be a bitmap
    /// from `CommittedRenderer.makeBitmap` of the same size. Returns false if it isn't, or if the data
    /// doesn't decode; then whatever `ctx` holds must be rendered again.
    func restore(into ctx: CGContext) -> Bool {
        guard let data = ctx.data, ctx.width == pixelWidth, ctx.height == pixelHeight,
              ctx.bytesPerRow == bytesPerRow, ctx.bitsPerPixel == 32,
              ctx.bitmapInfo.rawValue == CommittedRenderer.bitmapInfo
        else { return false }
        let length = bytesPerRow * pixelHeight
        let decoded = compressed.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(data.assumingMemoryBound(to: UInt8.self), length, base, source.count,
                                             nil, COMPRESSION_LZFSE)
        }
        return decoded == length
    }
}
