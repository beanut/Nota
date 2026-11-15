import CoreGraphics
import Foundation
import Metal
import simd

/// Draws raster brushes (a `wax` texture, the crayon) with Metal, wherever strokes are drawn: the live
/// layer, the committed bitmap and its bands, page images, thumbnails and exports all go through
/// `StrokeRenderer.draw`, which hands raster strokes here.
///
/// For the part of the stroke inside the context's clip, in the context's own pixels:
/// 1. the stroke's nib stamps are drawn as instanced ellipses into a pressure field, max-blended, so each
///    pixel holds the strongest press over it;
/// 2. a compute pass turns pressure into wax on a paper tooth computed from the page position, so the
///    grain is fixed to the page: it doesn't shimmer as the stroke grows, and any split of the work (tiles,
///    bands, the live layer's dirty rects) gives the same pixels;
/// 3. the result is drawn into the context as an image, with the brush's blend mode.
///
/// Shaders: `WaxShaders.swift`. Without a Metal device, or for a region too big to rasterize, `draw`
/// returns false and the caller fills the stroke's paths with the grain pattern instead.
final class WaxRenderer: @unchecked Sendable {
    /// Nil where Metal isn't available or the shaders don't load. Built on first use, on any thread.
    static let shared: WaxRenderer? = WaxRenderer()

    /// Largest region side rasterized in one pass; bigger regions are split into tiles of this size.
    static let tileSide = 2048
    /// Largest region drawn at all, in pixels; beyond it (a huge export) the grain pattern is used.
    static let maxPixels = 8192 * 8192

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stampPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: WaxShaders.source, options: nil),
              let vertex = library.makeFunction(name: "waxStampVertex"),
              let fragment = library.makeFunction(name: "waxStampFragment"),
              let composite = library.makeFunction(name: "waxComposite")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Wax stamps"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = Self.fieldFormat
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .max
        attachment?.alphaBlendOperation = .max
        attachment?.sourceRGBBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = .one
        guard let stampPipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let compositePipeline = try? device.makeComputePipelineState(function: composite)
        else { return nil }
        self.device = device
        self.queue = queue
        self.stampPipeline = stampPipeline
        self.compositePipeline = compositePipeline
    }

    private static let fieldFormat = MTLPixelFormat.r16Float

    /// Starts building the shared renderer in the background, so the first crayon stroke doesn't wait for
    /// the shaders.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            _ = shared
        }
    }

    // MARK: Drawing

    /// Draws `runs`' stamps into `ctx` (in canvas space), limited to `clip` (canvas space) and the context's
    /// clip, waiting for the GPU. Returns false, having drawn nothing, when the GPU can't draw it; the
    /// caller then fills paths.
    func draw(runs: [StrokeRun], clip: CGRect, brush: BrushDescriptor, color: RGBA, in ctx: CGContext) -> Bool {
        let toDevice = ctx.userSpaceToDeviceSpaceTransform
        let visible = ctx.boundingBoxOfClipPath.intersection(clip)
        guard !visible.isNull, !visible.isInfinite else { return true }
        guard let job = encode(runs: runs, over: nil, region: visible.applying(toDevice).integral,
                               toDevice: toDevice, ink: Ink(brush: brush, color: color))
        else { return false }
        guard !job.tiles.isEmpty else { return true }
        job.commands.commit()
        job.commands.waitUntilCompleted()
        guard let images = job.images() else { return false }
        Self.draw(images, in: ctx, blend: brush.blend.cgBlendMode)
        return true
    }

    /// The wax of `runs` over `field`'s baked pressure, in `region` (device pixels of the field, clipped to
    /// it), without waiting: `completion` gets the pixels on the main queue, or nil if the GPU failed.
    /// The live layer uses it, so a touch event never waits for the GPU.
    func render(runs: [StrokeRun], over field: WaxField, region: CGRect, ink: Ink,
                completion: @escaping @MainActor ([(CGRect, CGImage)]?) -> Void) -> Bool {
        guard let job = encode(runs: runs, over: field, region: region.integral.intersection(field.rect),
                               toDevice: field.toDevice, ink: ink)
        else { return false }
        let start = DispatchTime.now().uptimeNanoseconds
        job.commands.addCompletedHandler { [weak self] _ in
            let images = job.images()
            let latency = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            DispatchQueue.main.async {
                self?.latencyObserver?(latency)
                completion(images)
            }
        }
        job.commands.commit()
        return true
    }

    /// What a stroke is drawn with.
    struct Ink {
        let brush: BrushDescriptor
        let color: RGBA
    }

    /// Told how long each `render` took from commit to pixels, in milliseconds (for the benchmarks).
    var latencyObserver: ((Double) -> Void)?

    /// Draws GPU tiles into `ctx` (any user space): they're in its device pixels.
    static func draw(_ images: [(CGRect, CGImage)], in ctx: CGContext, blend: CGBlendMode) {
        ctx.saveGState()
        ctx.concatenate(ctx.userSpaceToDeviceSpaceTransform.inverted()) // user space is now device space
        ctx.setBlendMode(blend)
        ctx.interpolationQuality = .none
        for (rect, image) in images {
            ctx.draw(image, in: rect)
        }
        ctx.restoreGState()
    }

    /// One encoded (not committed) draw: its command buffer and where each tile of pixels lands.
    private struct Job {
        let commands: MTLCommandBuffer
        let tiles: [(rect: CGRect, output: MTLBuffer)]

        /// The pixels, once the command buffer has completed.
        func images() -> [(CGRect, CGImage)]? {
            guard commands.status == .completed else { return nil }
            let images = tiles.compactMap { tile in
                WaxRenderer.image(of: tile.output, size: tile.rect.size).map { (tile.rect, $0) }
            }
            return images.count == tiles.count ? images : nil
        }
    }

    /// Encodes the wax of `runs` (plus `field`'s pressure) over `region`, in device pixels from `toDevice`,
    /// split into tiles of at most `tileSide`. Nil when the GPU can't; no tiles when there's nothing to draw.
    private func encode(runs: [StrokeRun], over field: WaxField?, region: CGRect, toDevice: CGAffineTransform,
                        ink: Ink) -> Job? {
        let color = ink.color
        guard let grain = ink.brush.texture.grain, let commands = queue.makeCommandBuffer() else { return nil }
        commands.label = "Wax stroke"
        guard !region.isNull, !region.isInfinite, region.width >= 1, region.height >= 1 else {
            return Job(commands: commands, tiles: [])
        }
        guard region.width * region.height <= CGFloat(Self.maxPixels) else { return nil }
        let stamps = Self.deviceStamps(runs, toDevice: toDevice)
        guard !stamps.isEmpty || field != nil else { return Job(commands: commands, tiles: []) }
        let pixelsPerPoint = Float(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c).squareRoot())
        let style = Style(color: SIMD4(Float(color.r), Float(color.g), Float(color.b), Float(color.a)),
                          toothSize: Float(Self.toothPoints * grain.scale), contrast: Float(grain.contrast),
                          seed: grain.seed, pixelsPerPoint: pixelsPerPoint, toCanvas: toDevice.inverted())
        // Tiles of the region, in device pixels; y up, like the device space.
        var tiles: [(rect: CGRect, output: MTLBuffer)] = []
        let side = CGFloat(Self.tileSide)
        var y = region.minY
        while y < region.maxY {
            var x = region.minX
            while x < region.maxX {
                let rect = CGRect(x: x, y: y, width: min(side, region.maxX - x), height: min(side, region.maxY - y))
                let inside = stamps.filter { $0.bounds.intersects(rect) }
                if !inside.isEmpty || field != nil {
                    guard let output = encode(inside, in: rect, over: field, style: style, into: commands)
                    else { return nil }
                    tiles.append((rect, output))
                }
                x += side
            }
            y += side
        }
        return Job(commands: commands, tiles: tiles)
    }

    // MARK: Baked fields

    /// The pressure of a live stroke's settled chunks over one rect of a destination's pixels, kept on the
    /// GPU between draws. Max blending is order-free, so the stamps of baked chunks plus the hot ones drawn
    /// over them make exactly the field of the whole stroke, and the live layer's pixels match the
    /// committed ones.
    final class WaxField {
        fileprivate let texture: MTLTexture
        /// The device pixels it covers (y up).
        let rect: CGRect
        /// Canvas space to those pixels.
        let toDevice: CGAffineTransform

        fileprivate init(texture: MTLTexture, rect: CGRect, toDevice: CGAffineTransform) {
            self.texture = texture
            self.rect = rect
            self.toDevice = toDevice
        }

        /// Bytes held on the GPU.
        var bytes: Int {
            texture.width * texture.height * 2
        }
    }

    /// An empty field over `rect` (device pixels, from `toDevice`), or nil if the GPU can't make one.
    func makeField(covering rect: CGRect, toDevice: CGAffineTransform) -> WaxField? {
        let rect = rect.integral
        guard rect.width >= 1, rect.height >= 1, rect.width <= CGFloat(Self.tileSide),
              rect.height <= CGFloat(Self.tileSide),
              let texture = makeFieldTexture(width: Int(rect.width), height: Int(rect.height)),
              let commands = queue.makeCommandBuffer(),
              let pass = commands.makeRenderCommandEncoder(descriptor: Self.fieldPass(texture, clear: true))
        else { return nil }
        pass.endEncoding()
        commands.commit()
        return WaxField(texture: texture, rect: rect, toDevice: toDevice)
    }

    /// Adds `runs`' stamps to `field`. Doesn't wait: the next draw on the same queue runs after it.
    func bake(_ runs: [StrokeRun], into field: WaxField) {
        let stamps = Self.deviceStamps(runs, toDevice: field.toDevice).filter { $0.bounds.intersects(field.rect) }
        guard !stamps.isEmpty, let commands = queue.makeCommandBuffer() else { return }
        commands.label = "Wax bake"
        guard renderStamps(stamps, in: field.rect, into: field.texture, clear: false, commands: commands) else { return }
        commands.commit()
    }

    /// The tooth cell at grain scale 1, in canvas points.
    static let toothPoints: CGFloat = 1.6

    private struct Style {
        let color: SIMD4<Float>
        let toothSize: Float
        let contrast: Float
        let seed: UInt32
        let pixelsPerPoint: Float
        let toCanvas: CGAffineTransform
    }

    /// A stamp in device pixels, with its device bounds for culling.
    private struct DeviceStamp {
        var center: SIMD2<Float>
        var axisA: SIMD2<Float>
        var axisB: SIMD2<Float>
        var alpha: Float
        let bounds: CGRect
    }

    /// Matches `WaxStamp` in the shader.
    private struct GPUStamp {
        var center: SIMD2<Float>
        var axisA: SIMD2<Float>
        var axisB: SIMD2<Float>
        var alpha: Float
        var pad: Float = 0
    }

    /// Matches `WaxParams` in the shader.
    private struct GPUParams {
        var pageOrigin: SIMD2<Float>
        var pageStepX: SIMD2<Float>
        var pageStepY: SIMD2<Float>
        var color: SIMD4<Float>
        var toothSize: Float
        var contrast: Float
        var pixelsPerPoint: Float
        var seed: UInt32
        var width: UInt32
        var height: UInt32
        var rowPixels: UInt32
        var pad: UInt32 = 0
    }

    /// Every stamp of `runs` in device pixels. A stamp under about a pixel across is grown to that and
    /// pressed proportionally less, so a thin stroke zoomed out doesn't break up between pixel centres.
    private static func deviceStamps(_ runs: [StrokeRun], toDevice: CGAffineTransform) -> [DeviceStamp] {
        let minimum: CGFloat = 0.75
        var result: [DeviceStamp] = []
        result.reserveCapacity(runs.reduce(0) { $0 + $1.stamps.count })
        for run in runs {
            for tip in run.stamps {
                let c = cos(tip.angle), s = sin(tip.angle)
                var a = CGPoint(x: c * tip.major, y: s * tip.major).applyingLinear(toDevice)
                var b = CGPoint(x: -s * tip.minor, y: c * tip.minor).applyingLinear(toDevice)
                var alpha = tip.alpha
                let la = a.length, lb = b.length
                if la < minimum, la > 0 {
                    alpha *= la / minimum
                    a *= minimum / la
                }
                if lb < minimum, lb > 0 {
                    alpha *= lb / minimum
                    b *= minimum / lb
                }
                guard alpha > 0.002, la > 0, lb > 0 else { continue }
                let center = tip.center.applying(toDevice)
                let ex = abs(a.x) + abs(b.x), ey = abs(a.y) + abs(b.y)
                result.append(DeviceStamp(center: SIMD2(Float(center.x), Float(center.y)),
                                          axisA: SIMD2(Float(a.x), Float(a.y)), axisB: SIMD2(Float(b.x), Float(b.y)),
                                          alpha: Float(min(alpha, 1)),
                                          bounds: CGRect(x: center.x - ex, y: center.y - ey, width: 2 * ex,
                                                         height: 2 * ey)))
            }
        }
        return result
    }

    private func makeFieldTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.fieldFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private static func fieldPass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// Draws `stamps` (device pixels) into `texture`, which covers `rect`: row 0 at the top.
    private func renderStamps(_ stamps: [DeviceStamp], in rect: CGRect, into texture: MTLTexture, clear: Bool,
                              commands: MTLCommandBuffer) -> Bool {
        guard let render = commands.makeRenderCommandEncoder(descriptor: Self.fieldPass(texture, clear: clear))
        else { return false }
        defer { render.endEncoding() }
        guard !stamps.isEmpty else { return true }
        let origin = SIMD2(Float(rect.minX), Float(rect.minY))
        let gpuStamps = stamps.map {
            GPUStamp(center: $0.center - origin, axisA: $0.axisA, axisB: $0.axisB, alpha: $0.alpha)
        }
        guard let buffer = gpuStamps.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { return false }
        render.setRenderPipelineState(stampPipeline)
        render.setVertexBuffer(buffer, offset: 0, index: 0)
        var size = SIMD2(Float(rect.width), Float(rect.height))
        render.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: gpuStamps.count)
        return true
    }

    /// Encodes both passes for one tile of the region and returns the buffer its pixels land in:
    /// premultiplied RGBA, rows top to bottom. With `base`, the tile's field starts as a copy of that part
    /// of it (`rect` must lie inside it).
    private func encode(_ stamps: [DeviceStamp], in rect: CGRect, over base: WaxField?, style: Style,
                        into commands: MTLCommandBuffer) -> MTLBuffer? {
        let width = Int(rect.width), height = Int(rect.height)
        let rowPixels = width
        guard let field = makeFieldTexture(width: width, height: height),
              let output = device.makeBuffer(length: rowPixels * height * 4, options: .storageModeShared)
        else { return nil }
        if let base {
            // Rows count down from the top in both textures.
            guard let blit = commands.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: base.texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: Int(rect.minX - base.rect.minX), y: Int(base.rect.maxY - rect.maxY),
                                              z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: field, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        guard renderStamps(stamps, in: rect, into: field, clear: base == nil, commands: commands) else { return nil }

        // Pixel (i, j), row 0 at the top, has its centre at device (minX + i + 0.5, maxY - j - 0.5).
        let toCanvas = style.toCanvas
        let first = CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5).applying(toCanvas)
        let right = CGPoint(x: 1, y: 0).applyingLinear(toCanvas)
        let down = CGPoint(x: 0, y: -1).applyingLinear(toCanvas)
        var params = GPUParams(pageOrigin: SIMD2(Float(first.x), Float(first.y)),
                               pageStepX: SIMD2(Float(right.x), Float(right.y)),
                               pageStepY: SIMD2(Float(down.x), Float(down.y)),
                               color: style.color, toothSize: style.toothSize, contrast: style.contrast,
                               pixelsPerPoint: style.pixelsPerPoint, seed: style.seed, width: UInt32(width),
                               height: UInt32(height), rowPixels: UInt32(rowPixels))
        guard let compute = commands.makeComputeCommandEncoder() else { return nil }
        compute.setComputePipelineState(compositePipeline)
        compute.setTexture(field, index: 0)
        compute.setBuffer(output, offset: 0, index: 0)
        compute.setBytes(&params, length: MemoryLayout<GPUParams>.stride, index: 1)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        compute.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        compute.endEncoding()
        return output
    }

    /// The tile's pixels as an sRGB image, without copying them: the image keeps the buffer alive.
    fileprivate static func image(of buffer: MTLBuffer, size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        let info = Unmanaged.passRetained(buffer as AnyObject).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: buffer.contents(), size: buffer.length,
                                            releaseData: { info, _, _ in
                                                if let info {
                                                    Unmanaged<AnyObject>.fromOpaque(info).release()
                                                }
                                            })
        else {
            Unmanaged<AnyObject>.fromOpaque(info).release()
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private extension CGPoint {
    /// The point transformed by `t`'s linear part only (a direction, not a position).
    func applyingLinear(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y, y: t.b * x + t.d * y)
    }

    var length: CGFloat {
        (x * x + y * y).squareRoot()
    }

    static func *= (point: inout CGPoint, scale: CGFloat) {
        point = point * scale
    }
}
