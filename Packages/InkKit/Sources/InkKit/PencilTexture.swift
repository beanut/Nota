import CoreGraphics
import UIKit

/// Generates and caches seamless graphite / paper-tooth pattern colors for grain-textured brushes
/// (`BrushDescriptor.Texture.grain`), such as the pencil.
enum PencilTexture {
    static let patternSize = 64
    private static let lock = NSLock()
    private static var heightMaps: [UInt32: [Float]] = [:]

    /// Where a thread keeps its own pattern colours (`fillColor`).
    private static let threadColorsKey = "InkKit.PencilTexture.colors"

    /// A grain's parameters (see `BrushDescriptor.Texture.grain`).
    struct Grain: Hashable {
        var scale: CGFloat
        var contrast: CGFloat
        var seed: UInt32

        /// The pencil's grain.
        static let pencil = Grain(scale: 1, contrast: 1, seed: 42)
    }

    private struct CacheKey: Hashable {
        let r: Int
        let g: Int
        let b: Int
        let a: Int
        let alphaIndex: Int
        let grain: Grain
    }

    /// The 64x64 periodic paper-tooth height map for `seed`, in [0, 1], built once per seed.
    private static func heightMap(seed: UInt32) -> [Float] {
        lock.lock()
        if let map = heightMaps[seed] {
            lock.unlock()
            return map
        }
        lock.unlock()
        let map = makeHeightMap(seed: seed)
        lock.lock()
        heightMaps[seed] = map
        lock.unlock()
        return map
    }

    /// Combines primary paper fiber cells, fine tooth cells, and micro-flecks, with periodic toroidal
    /// wrapping for seamless tiling. The seed places the cells; the flecks are the same for every seed.
    private static func makeHeightMap(seed initialSeed: UInt32) -> [Float] {
        let w = patternSize
        let h = patternSize
        var map = [Float](repeating: 0, count: w * h)

        func periodicDistSq(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> Float {
            var dx = abs(x1 - x2)
            var dy = abs(y1 - y2)
            let wf = Float(w), hf = Float(h)
            if dx > wf * 0.5 {
                dx = wf - dx
            }
            if dy > hf * 0.5 {
                dy = hf - dy
            }
            return dx * dx + dy * dy
        }

        // Deterministic pseudo-random number generator for consistent paper tooth across launches
        var seed = UInt64(initialSeed)
        func nextRandom() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float((seed >> 32) & 0x7FFF_FFFF) / Float(0x7FFF_FFFF)
        }

        // Primary paper fiber cells
        let primaryCount = 48
        var primaryCells = [(x: Float, y: Float)]()
        primaryCells.reserveCapacity(primaryCount)
        for _ in 0 ..< primaryCount {
            primaryCells.append((nextRandom() * Float(w), nextRandom() * Float(h)))
        }

        // Secondary fine paper tooth cells
        let fineCount = 120
        var fineCells = [(x: Float, y: Float)]()
        fineCells.reserveCapacity(fineCount)
        for _ in 0 ..< fineCount {
            fineCells.append((nextRandom() * Float(w), nextRandom() * Float(h)))
        }

        for y in 0 ..< h {
            let yf = Float(y)
            for x in 0 ..< w {
                let xf = Float(x)

                var minPrimarySq = Float.greatestFiniteMagnitude
                for c in primaryCells {
                    let d = periodicDistSq(xf, yf, c.x, c.y)
                    if d < minPrimarySq {
                        minPrimarySq = d
                    }
                }
                let tooth1 = exp(-minPrimarySq / (2.0 * 3.5 * 3.5))

                var minFineSq = Float.greatestFiniteMagnitude
                for c in fineCells {
                    let d = periodicDistSq(xf, yf, c.x, c.y)
                    if d < minFineSq {
                        minFineSq = d
                    }
                }
                let tooth2 = exp(-minFineSq / (2.0 * 2.0 * 2.0))

                // High-frequency graphite micro-flecks via integer hash
                var n = UInt32(x) &* 374_761_393 &+ UInt32(y) &* 668_265_263
                n = (n ^ (n >> 13)) &* 1_274_126_177
                let fleck = Float((n ^ (n >> 16)) & 0xFFFF) / 65535.0

                let combined = 0.45 * tooth1 + 0.35 * tooth2 + 0.20 * fleck
                map[y * w + x] = min(max(combined, 0.0), 1.0)
            }
        }
        return map
    }

    /// Prepares the graphics context with the proper pattern phase in device coordinates,
    /// ensuring seamless alignment across tile boundaries and during canvas panning.
    static func prepareContext(_ ctx: CGContext, phase: CGPoint = .zero) {
        let size = CGFloat(patternSize)
        let px = phase.x.truncatingRemainder(dividingBy: size)
        let py = phase.y.truncatingRemainder(dividingBy: size)
        ctx.setPatternPhase(CGSize(width: px, height: py))
    }

    /// Pins the grain to the page: anchors the pattern at the device pixel where `ctx`'s current user
    /// space (page points) puts the page's origin. The pattern is anchored at the bitmap's bottom-left
    /// corner in device pixels, so every bitmap that sets this, whatever part of the page it covers and
    /// wherever it sits on screen (a committed tile, a live tile, a pan later), shows the same grain on the
    /// same page pixel. The phase isn't reduced modulo the 64-pixel cell: a scaled grain's cell isn't 64.
    static func pinToPage(_ ctx: CGContext) {
        let origin = CGPoint.zero.applying(ctx.ctm)
        ctx.setPatternPhase(CGSize(width: origin.x, height: origin.y))
    }

    /// Returns a seamless pattern CGColor representing the graphite stroke texture
    /// for the given base color, run alpha and grain.
    static func fillColor(for color: RGBA, alpha: CGFloat, grain: Grain = .pencil) -> CGColor {
        let clampedAlpha = min(max(alpha, 0.0), 1.0)
        let alphaIndex = Int((clampedAlpha * StrokeRenderer.alphaSteps).rounded())

        let key = CacheKey(
            r: Int(round(color.r * 255)),
            g: Int(round(color.g * 255)),
            b: Int(round(color.b * 255)),
            a: Int(round(color.a * 255)),
            alphaIndex: alphaIndex,
            grain: grain
        )

        // Each thread makes and keeps pattern colours of its own, images and all. Core Graphics caches what
        // it rasterized of a pattern's image for a context's scale and phase, and one pattern image filling
        // contexts at different levels on several threads at once left a few pixels of one thread's
        // rasterization in another's tile, so tile fills running side by side weren't the pixels a fill
        // alone gives (NOT-112). A pattern is 16 KB; a thread uses a handful.
        let local = Thread.current.threadDictionary
        var colors = local[threadColorsKey] as? [CacheKey: CGColor] ?? [:]
        if let cached = colors[key] {
            return cached
        }

        let w = patternSize
        let h = patternSize
        var pixelBytes = [UInt8](repeating: 0, count: w * h * 4)

        let a = Float(clampedAlpha * color.a)
        let r = Float(color.r)
        let g = Float(color.g)
        let b = Float(color.b)

        // As alpha drops (e.g. tilted shading), paper tooth gaps become more pronounced;
        // as alpha increases, graphite fills more of the tooth.
        let expFactor = 1.4 - 0.6 * a
        // Contrast 1 is the pencil: 15% of the ink everywhere, the rest where the tooth is high.
        let contrast = Float(grain.contrast)
        let floor = 0.15 + 0.85 * (1 - contrast), gain = 0.85 * contrast
        let heightMap = heightMap(seed: grain.seed)

        for i in 0 ..< (w * h) {
            let heightVal = heightMap[i]
            let tooth = pow(heightVal, expFactor)
            let pixelAlpha = a * (floor + gain * tooth)

            // Premultiplied RGBA byte order
            let offset = i * 4
            pixelBytes[offset] = UInt8(round(min(max(r * pixelAlpha * 255.0, 0), 255)))
            pixelBytes[offset + 1] = UInt8(round(min(max(g * pixelAlpha * 255.0, 0), 255)))
            pixelBytes[offset + 2] = UInt8(round(min(max(b * pixelAlpha * 255.0, 0), 255)))
            pixelBytes[offset + 3] = UInt8(round(min(max(pixelAlpha * 255.0, 0), 255)))
        }

        let data = Data(pixelBytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            return color.cgColor(alpha: clampedAlpha)
        }

        // A larger grain is the same tile drawn bigger.
        let uiImage = grain.scale == 1 ? UIImage(cgImage: cgImage)
            : UIImage(cgImage: cgImage, scale: 1 / grain.scale, orientation: .up)
        let patternColor = UIColor(patternImage: uiImage).cgColor
        colors[key] = patternColor
        local[threadColorsKey] = colors
        return patternColor
    }
}
