import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Names an image's bytes: the SHA-256 of them, as 64 lowercase hex digits. The same picture inserted twice
/// (or pasted into another note) has the same id, so its bytes are stored once per note.
public typealias ImageAssetID = String

/// Where the bytes of the images on pages come from, and their decoded, downsampled bitmaps.
///
/// InkKit doesn't know where a note keeps its files. An `ImageObject` names its picture by `ImageAssetID`;
/// this registry finds the bytes for that id: in memory for a picture just inserted or pasted, or in a
/// file a host app has `register`ed (Nota's `DocumentStore` registers each note package's `assets/`
/// folder when it opens the note, and writes new pictures there, calling `didPersist`, when it saves).
/// Because an id is a content hash, one process-wide registry (`shared`) serves every note.
///
/// **Display.** Pictures are never drawn at full size: `image(for:pixelSize:waits:)` decodes a thumbnail
/// (ImageIO, EXIF orientation applied) at the next power of two above the size it's shown at, and caches
/// it. The canvas asks without waiting (`ImageDrawing.defersDecoding`), drawing whatever size is cached
/// while the right one decodes in the background, then redraws on `didLoadImageNotification`; still
/// images (thumbnails, PDFs, copies for other apps) wait for it.
///
/// Thread-safe.
public final class ImageAssets: @unchecked Sendable {
    /// The registry every editor and every note shares.
    public static let shared = ImageAssets()

    /// Posted on the main thread when a bitmap decoded in the background is ready; `userInfo["id"]` is
    /// the asset's id.
    public static let didLoadImageNotification = Notification.Name("InkKit.ImageAssets.didLoadImage")

    private struct State {
        /// Bytes not yet in a file a host has registered.
        var memory: [ImageAssetID: Data] = [:]
        /// Files holding each asset; any readable one will do.
        var files: [ImageAssetID: [URL]] = [:]
        /// Oriented pixel sizes, once read.
        var sizes: [ImageAssetID: CGSize] = [:]
        /// Thumbnail sizes decoded for each asset (they may since have been evicted from the cache).
        var decoded: [ImageAssetID: Set<Int>] = [:]
        /// Background decodes under way, as cache keys.
        var loading: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cache = NSCache<NSString, CGImage>()
    private let decodeQueue = DispatchQueue(label: "InkKit.ImageAssets.decode", qos: .userInitiated, attributes: .concurrent)

    /// The smallest thumbnail decoded, in pixels along the longer side.
    static let smallestThumbnail = 256

    public init() {
        cache.totalCostLimit = 192 << 20 // bytes of decoded bitmaps
    }

    // MARK: Ids and bytes

    /// The id `data` is stored under.
    public static func id(for data: Data) -> ImageAssetID {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps `data` (the bytes of an image file: JPEG, HEIC, PNG…) until a host persists it, and returns
    /// its id. Nil if ImageIO can't read it as an image.
    @discardableResult
    public func add(_ data: Data) -> ImageAssetID? {
        guard let size = Self.pixelSize(of: data) else { return nil }
        let id = Self.id(for: data)
        state.withLock {
            if $0.memory[id] == nil {
                $0.memory[id] = data
            }
            $0.sizes[id] = size
        }
        return id
    }

    /// Records that `url` holds the bytes of asset `id` (a file in a note package).
    public func register(fileURL url: URL, for id: ImageAssetID) {
        state.withLock {
            var urls = $0.files[id] ?? []
            if !urls.contains(url) {
                urls.append(url)
            }
            $0.files[id] = urls
        }
    }

    /// A host wrote asset `id` to `url`: the registry reads it from there from now on, and lets its copy in
    /// memory go.
    public func didPersist(_ id: ImageAssetID, at url: URL) {
        register(fileURL: url, for: id)
        state.withLock { _ = $0.memory.removeValue(forKey: id) }
    }

    /// The asset's bytes, from memory or the first of its files that can still be read. Nil if none can.
    public func data(for id: ImageAssetID) -> Data? {
        let (memory, urls) = state.withLock { ($0.memory[id], $0.files[id] ?? []) }
        if let memory {
            return memory
        }
        for url in urls {
            if let data = try? Data(contentsOf: url), Self.id(for: data) == id {
                return data
            }
        }
        return nil
    }

    /// Whether the registry can find the asset's bytes (without reading them).
    public func contains(_ id: ImageAssetID) -> Bool {
        state.withLock { $0.memory[id] != nil || !($0.files[id]?.isEmpty ?? true) }
    }

    /// The file extension for `data`'s image type (`jpeg`, `heic`, `png`…), for naming its file.
    public static func fileExtension(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String)
        else { return "img" }
        return type.preferredFilenameExtension ?? "img"
    }

    /// The image's size in pixels as it's shown, with its EXIF orientation applied. Nil if it isn't an image.
    public static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Orientations 5–8 turn the picture a quarter turn.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    // MARK: Bitmaps

    /// The thumbnail size (longer side, pixels) to decode for showing an image `pixelSize` pixels along its
    /// longer side: the next power of two from 256, or 0 (the full image) once that reaches `fullSize`.
    static func bucket(for pixelSize: CGFloat, fullSize: CGFloat) -> Int {
        guard pixelSize.isFinite, fullSize > 0 else { return 0 }
        var bucket = smallestThumbnail
        while CGFloat(bucket) < pixelSize, bucket < 16384 {
            bucket *= 2
        }
        return CGFloat(bucket) >= fullSize ? 0 : bucket
    }

    /// A bitmap of the asset at least `pixelSize` pixels along its longer side (or the whole image, if
    /// that's smaller), oriented. With `waits`, decodes it now if it isn't cached; without, returns the
    /// nearest size already decoded (nil if none) and decodes the right one in the background, posting
    /// `didLoadImageNotification` when it's ready.
    public func image(for id: ImageAssetID, pixelSize: CGFloat, waits: Bool) -> CGImage? {
        let full = fullSize(of: id)
        let bucket = Self.bucket(for: pixelSize, fullSize: full.map { max($0.width, $0.height) } ?? 0)
        let key = Self.key(id, bucket)
        if let image = cache.object(forKey: key) {
            return image
        }
        if waits {
            return decode(id, bucket: bucket)
        }
        let loadingKey = key as String
        let start = state.withLock { $0.loading.insert(loadingKey).inserted }
        if start {
            decodeQueue.async { [weak self] in
                guard let self else { return }
                _ = decode(id, bucket: bucket)
                state.withLock { _ = $0.loading.remove(loadingKey) }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.didLoadImageNotification, object: self, userInfo: ["id": id])
                }
            }
        }
        return nearestCached(id, to: bucket)
    }

    /// Drops every decoded bitmap (memory warnings, tests).
    public func purgeBitmaps() {
        cache.removeAllObjects()
        state.withLock { $0.decoded.removeAll() }
    }

    private func fullSize(of id: ImageAssetID) -> CGSize? {
        if let size = state.withLock({ $0.sizes[id] }) {
            return size
        }
        guard let data = data(for: id), let size = Self.pixelSize(of: data) else { return nil }
        state.withLock { $0.sizes[id] = size }
        return size
    }

    private static func key(_ id: ImageAssetID, _ bucket: Int) -> NSString {
        "\(id)@\(bucket)" as NSString
    }

    private func nearestCached(_ id: ImageAssetID, to bucket: Int) -> CGImage? {
        let sizes = state.withLock { $0.decoded[id] ?? [] }
        let target = bucket == 0 ? Int.max : bucket
        // Prefer the largest smaller one (cheap to draw), then the smallest larger one.
        let ordered = sizes.sorted { a, b in
            let da = a == 0 ? Int.max : a, db = b == 0 ? Int.max : b
            if (da <= target) != (db <= target) {
                return da <= target
            }
            return da <= target ? da > db : da < db
        }
        for size in ordered {
            if let image = cache.object(forKey: Self.key(id, size)) {
                return image
            }
        }
        return nil
    }

    private func decode(_ id: ImageAssetID, bucket: Int) -> CGImage? {
        guard let data = data(for: id), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if bucket > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = bucket
        } else if let size = fullSize(of: id) {
            options[kCGImageSourceThumbnailMaxPixelSize] = Int(max(size.width, size.height))
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: Self.key(id, bucket), cost: image.bytesPerRow * image.height)
        state.withLock { $0.decoded[id, default: []].insert(bucket) }
        return image
    }
}

/// How images are drawn on the current thread: the canvas defers decoding (`ImageAssets`), and PDF export
/// asks for a higher resolution than the PDF's own point grid.
enum ImageDrawing {
    struct Options {
        /// Draw what's cached and decode the rest in the background, instead of waiting.
        var defersDecoding = false
        /// Pixels per page point to decode at, at least, whatever the context's scale.
        var minimumScale: CGFloat = 0
    }

    private static let key = "InkKit.ImageDrawing.options"

    static var current: Options {
        (Thread.current.threadDictionary[key] as? Box)?.options ?? Options()
    }

    /// Runs `body` with `options` in force on this thread.
    static func with<T>(_ options: Options, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = Box(options: options)
        defer { dictionary[key] = previous }
        return try body()
    }

    private final class Box {
        let options: Options

        init(options: Options) {
            self.options = options
        }
    }
}
