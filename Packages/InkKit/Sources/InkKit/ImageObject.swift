import CoreGraphics
import Foundation

/// A picture on the page: a photo, a scan, a pasted or dropped image, or a sticker's image.
///
/// **Bytes.** The object only names its picture (`asset`, a content hash; see `ImageAssets`), so a picture
/// placed many times is stored once, and the page's objects file stays small. `pixelSize` is the full
/// picture's size in pixels, oriented.
///
/// **Crop.** Cropping is non-destructive and can be changed or undone later. `crop` is the part of the
/// picture shown, in *unit image space* (0…1 across and down the whole picture, y down), and `frame` is
/// that part on the page: the whole picture would fill `imageRect`. A freehand crop adds `mask`, a closed
/// outline in unit image space; `crop` is then the outline's bounds. Cropping changes `frame`, never where
/// the picture sits: the part kept stays exactly where it was (`cropped(to:mask:)`).
///
/// **Look.** Drawn at `opacity` (5–100%), downsampled to the size it's shown at. Resizing, rotating and
/// layering are the object layer's, like any object; recolouring leaves a picture as it is.
///
/// File kind `"image"`; its own fields are `asset`, `pixelSize` (`[width, height]`), `crop` (`{x, y, width,
/// height}`, absent for the whole picture), `mask` (`[[x, y], …]`, absent without a freehand crop) and
/// `opacity` (absent for 1). Reading is lenient: a bad crop is the whole picture, a mask of fewer than three
/// points is no mask, and an opacity out of range is clamped, so a picture is never lost.
public struct ImageObject: PageObject, Equatable {
    public static let kind = "image"

    public let id: UUID
    public var frame: CGRect
    public var transform: CGAffineTransform
    public var zIndex: Int
    /// The picture's bytes in `ImageAssets`.
    public var asset: ImageAssetID
    /// The whole picture's size in pixels, with its orientation applied.
    public var pixelSize: CGSize
    /// The part of the picture shown, in unit image space. The whole picture is `unitRect`.
    public private(set) var crop: CGRect
    /// A freehand crop's outline in unit image space, or nil for a rectangular crop.
    public private(set) var mask: [CGPoint]?
    /// 0.05…1.
    public var opacity: CGFloat {
        didSet { opacity = Self.clampedOpacity(opacity) }
    }

    /// The whole picture in unit image space.
    public static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The smallest crop, as a fraction of the picture each way.
    static let minimumCrop: CGFloat = 0.02
    static let minimumOpacity: CGFloat = 0.05

    /// The whole picture `asset`, `pixelSize` pixels, filling `frame`.
    public init(id: UUID = UUID(), asset: ImageAssetID, pixelSize: CGSize, frame: CGRect,
                transform: CGAffineTransform = .identity, zIndex: Int = 0, opacity: CGFloat = 1) {
        self.id = id
        self.frame = frame
        self.transform = transform
        self.zIndex = zIndex
        self.asset = asset
        self.pixelSize = pixelSize
        crop = Self.unitRect
        mask = nil
        self.opacity = Self.clampedOpacity(opacity)
    }

    /// Whether only part of the picture is shown.
    public var isCropped: Bool {
        mask != nil || crop != Self.unitRect
    }

    // MARK: Geometry

    /// Where the whole picture would be, in the object's own space: `frame` is `crop` of it.
    public var imageRect: CGRect {
        let width = frame.width / crop.width, height = frame.height / crop.height
        return CGRect(x: frame.minX - crop.minX * width, y: frame.minY - crop.minY * height, width: width, height: height)
    }

    /// A unit-image-space point in the object's own space.
    func ownPoint(fromUnit p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }

    /// An own-space point in unit image space.
    func unitPoint(fromOwn p: CGPoint) -> CGPoint {
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return .zero }
        return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    /// The freehand crop's outline in the object's own space, if it has one.
    public var maskPath: CGPath? {
        guard let mask else { return nil }
        let path = CGMutablePath()
        path.addLines(between: mask.map(ownPoint(fromUnit:)))
        path.closeSubpath()
        return path
    }

    /// The picture showing `crop` of itself (unit image space), with `mask` as a freehand outline (nil for a
    /// rectangle). The picture doesn't move: the part kept stays where it is on the page. With a mask, the
    /// crop is the mask's bounds. Crops are kept inside the picture and at least `minimumCrop` each way.
    public func cropped(to crop: CGRect, mask: [CGPoint]? = nil) -> ImageObject {
        let image = imageRect
        var copy = self
        let unit = Self.unitRect
        let clampedMask = mask.map { $0.map { CGPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) } }
        if let clampedMask, clampedMask.count >= 3 {
            copy.mask = clampedMask
            copy.crop = Self.clampedCrop(Self.bounds(of: clampedMask))
        } else {
            copy.mask = nil
            copy.crop = Self.clampedCrop(crop.standardized.intersection(unit))
        }
        let c = copy.crop
        copy.frame = CGRect(x: image.minX + c.minX * image.width, y: image.minY + c.minY * image.height,
                            width: c.width * image.width, height: c.height * image.height)
        return copy
    }

    /// The whole picture again, where it was.
    public func uncropped() -> ImageObject {
        cropped(to: Self.unitRect)
    }

    /// Whether `point` (page space) is on the picture: inside its crop, and inside its freehand outline if it
    /// has one, or within `tolerance` page points of it.
    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let det = transform.a * transform.d - transform.b * transform.c
        guard abs(det) > 1e-12 else { return false }
        let scale = max(sqrt(abs(det)), 1e-6)
        let local = point.applying(transform.inverted())
        let slop = tolerance / scale
        guard frame.insetBy(dx: -slop, dy: -slop).contains(local) else { return false }
        guard let path = maskPath else { return true }
        if path.contains(local) {
            return true
        }
        return slop > 0 && path.copy(strokingWithWidth: 2 * slop, lineCap: .round, lineJoin: .round, miterLimit: 1)
            .contains(local)
    }

    static func clampedCrop(_ r: CGRect) -> CGRect {
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite, !r.isNull else { return unitRect }
        let width = min(max(r.width, minimumCrop), 1), height = min(max(r.height, minimumCrop), 1)
        let x = min(max(r.minX, 0), 1 - width), y = min(max(r.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func clampedOpacity(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, minimumOpacity), 1) : 1
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Drawing

    /// Draws the picture's crop into `frame`, at the resolution it's shown at (the context's scale).
    public func draw(in ctx: CGContext) {
        let image = imageRect
        let options = ImageDrawing.current
        let ctm = ctx.ctm
        let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        let shown = max(image.width, image.height) * max(deviceScale, options.minimumScale)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: frame)
        if let path = maskPath {
            ctx.addPath(path)
            ctx.clip()
        }
        ctx.setAlpha(opacity)
        guard let bitmap = ImageAssets.shared.image(for: asset, pixelSize: shown, waits: !options.defersDecoding) else {
            // Still decoding (or the bytes are missing): a quiet stand-in the size of the picture.
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.55, alpha: 0.12))
            ctx.fill(frame)
            return
        }
        // The canvas redraws its pictures as the page pans and zooms, across a layer of many megapixels,
        // and the bitmap it's given is within 2× of the size shown: bilinear is a fraction of the cost
        // there and looks the same. Stills (thumbnails, PDFs, copies) take the time to resample well.
        ctx.interpolationQuality = options.defersDecoding ? .low : .high
        // Canvas space is y-down; Core Graphics draws images y-up.
        ctx.translateBy(x: image.minX, y: image.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(bitmap, in: CGRect(origin: .zero, size: image.size))
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case asset, pixelSize, crop, mask, opacity
    }

    private struct Rect: Codable {
        var x, y, width, height: Double
    }

    public init(from decoder: Decoder) throws {
        let placement = try PageObjectPlacement(from: decoder)
        id = placement.id
        frame = placement.frame
        transform = placement.transform
        zIndex = placement.zIndex
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A picture whose asset can't be read is drawn as a stand-in rather than lost.
        asset = (try? c.decodeIfPresent(String.self, forKey: .asset)) ?? ""
        let size = (try? c.decodeIfPresent([Double].self, forKey: .pixelSize)) ?? []
        if size.count == 2, size.allSatisfy({ $0.isFinite && $0 > 0 }) {
            pixelSize = CGSize(width: size[0], height: size[1])
        } else {
            pixelSize = placement.frame.size
        }
        if let r = try? c.decodeIfPresent(Rect.self, forKey: .crop),
           [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite), r.width > 0, r.height > 0 {
            crop = Self.clampedCrop(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
        } else {
            crop = Self.unitRect
        }
        let pairs = (try? c.decodeIfPresent([[Double]].self, forKey: .mask)) ?? []
        let points = pairs.compactMap { pair -> CGPoint? in
            guard pair.count == 2, pair.allSatisfy(\.isFinite) else { return nil }
            return CGPoint(x: min(max(pair[0], 0), 1), y: min(max(pair[1], 0), 1))
        }
        mask = points.count >= 3 ? points : nil
        opacity = Self.clampedOpacity(CGFloat((try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1))
    }

    public func encode(to encoder: Encoder) throws {
        try PageObjectPlacement(of: self).encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(asset, forKey: .asset)
        try c.encode([Double(pixelSize.width), Double(pixelSize.height)], forKey: .pixelSize)
        if crop != Self.unitRect {
            try c.encode(Rect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height), forKey: .crop)
        }
        if let mask {
            try c.encode(mask.map { [Double($0.x), Double($0.y)] }, forKey: .mask)
        }
        if opacity < 1 {
            try c.encode(Double(opacity), forKey: .opacity)
        }
    }
}

public extension PageObjectsFile {
    /// Every picture the page's objects use, including any named by objects of kinds this version
    /// doesn't know (an `"asset"` field), so a host never throws away a picture a newer app's object needs.
    var imageAssetIDs: Set<ImageAssetID> {
        var ids = Set<ImageAssetID>()
        for object in objects {
            if let image = object as? ImageObject {
                if !image.asset.isEmpty {
                    ids.insert(image.asset)
                }
            } else if let unknown = object as? UnknownPageObject, case let .object(fields) = unknown.json,
                      case let .string(asset)? = fields["asset"] {
                ids.insert(asset)
            }
        }
        return ids
    }
}

extension Sequence<any PageObject> {
    /// The pictures these objects use.
    var imageAssetIDs: Set<ImageAssetID> {
        Set(compactMap { ($0 as? ImageObject)?.asset }.filter { !$0.isEmpty })
    }
}
