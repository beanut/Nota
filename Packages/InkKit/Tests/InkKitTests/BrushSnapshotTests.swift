import CoreGraphics
import Foundation
import ImageIO
@testable import InkKit
import Testing
import UniformTypeIdentifiers

/// Golden images of brushes. The built-in tools' PNGs in `Snapshots/` were rendered by the engine before
/// brushes became `BrushDescriptor`s (NOT-16), so these tests show the bundled descriptors draw what
/// `InkKind` + `BrushStyle` drew (they match pixel for pixel). The stamp and calligraphy scenes were
/// recorded when those paths were added, and each brush of the built-in set (NOT-17) has a scene of its
/// own, drawn at its default width with the Pressure & Tilt settings at their defaults. Set `TEST_RUNNER_INK_SNAPSHOT_RECORD=1` to
/// re-record them
/// after an intended change to how a brush looks, and say why in the PR.
@MainActor
@Suite("Brush snapshots")
struct BrushSnapshotTests {
    @Test(arguments: SnapshotScene.allCases)
    func matchesGolden(_ scene: SnapshotScene) throws {
        let image = try #require(scene.render())
        let url = snapshotDirectory.appendingPathComponent("\(scene.rawValue).png")
        if ProcessInfo.processInfo.environment["INK_SNAPSHOT_RECORD"] == "1" {
            try writePNG(image, to: url)
            return
        }
        let golden = try #require(loadPNG(url), "missing golden \(url.lastPathComponent)")
        let diff = try #require(compare(image, golden))
        // Identical up to rounding: at most a step or two in any channel, on a handful of pixels.
        #expect(diff.maxChannelDelta <= 2, "\(scene.rawValue): max channel delta \(diff.maxChannelDelta)")
        #expect(diff.differingPixels <= 16, "\(scene.rawValue): \(diff.differingPixels) pixels differ")
    }
}

// MARK: - Scenes

enum SnapshotScene: String, CaseIterable, CustomTestStringConvertible {
    case penFlat = "pen-flat"
    case penTilted = "pen-tilted"
    case penWide = "pen-wide"
    case pencilTilted = "pencil-tilted"
    case highlighterOverPen = "highlighter-over-pen"
    case pixelEraserOverPen = "pixel-eraser-over-pen"
    case stampDryBrush = "stamp-dry-brush"
    case calligraphyTaper = "calligraphy-taper"
    case fineliner = "brush-fineliner"
    case fountainPen = "brush-fountain-pen"
    case brushPen = "brush-brush-pen"
    case marker = "brush-marker"
    case dashedPen = "brush-dashed"
    case dottedPen = "brush-dotted"
    case softPencil = "brush-soft-pencil"
    case chiselHighlighter = "brush-chisel-highlighter"

    var testDescription: String {
        rawValue
    }

    static let pageSize = PageSize(width: 300, height: 160)

    var strokes: [Stroke] {
        switch self {
        case .penFlat:
            [brushStroke(.pen, width: 4, tilt: false, wave: 0)]
        case .penTilted:
            [brushStroke(.pen, width: 4, tilt: true, wave: 0), brushStroke(.pen, width: 2, tilt: true, wave: 1)]
        case .penWide:
            [brushStroke(.pen, width: 18, tilt: true, wave: 2)]
        case .pencilTilted:
            [brushStroke(.pencil, width: 3, tilt: true, wave: 0), brushStroke(.pencil, width: 6, tilt: true, wave: 1)]
        case .highlighterOverPen:
            [brushStroke(.pen, width: 4, tilt: false, wave: 0), brushStroke(.highlighter, width: 22, tilt: true, wave: 3)]
        case .pixelEraserOverPen:
            [brushStroke(.pen, width: 6, tilt: false, wave: 0), brushStroke(.pen, width: 3, tilt: true, wave: 1),
             brushStroke(.pixelEraser, width: 24, tilt: false, wave: 4)]
        case .stampDryBrush:
            [brushStroke(.pen, width: 4, tilt: false, wave: 0).with(BrushDescriptor(
                name: "Dry Brush", size: 4 ... 16, tilt: .off, texture: .bristle(count: 10, spread: 0.9),
                spacing: 0.25, jitter: .init(size: 0.3, angle: 0.2, scatter: 0.15, opacity: 0.4, seed: 3)
            )),
            brushStroke(.pen, width: 4, tilt: false, wave: 1).with(BrushDescriptor(
                name: "Dotted", size: 2 ... 5, tilt: .off, spacing: 1.6
            ))]
        case .calligraphyTaper:
            [brushStroke(.pen, width: 4, tilt: false, wave: 0).with(BrushDescriptor(
                name: "Italic", tip: .ellipse(aspect: 0.2, angle: 0.7), size: 3 ... 10, tilt: .off,
                taper: .init(startLength: 30, endLength: 40)
            )),
            brushStroke(.pen, width: 4, tilt: false, wave: 1).with(BrushDescriptor(
                name: "Wet", size: 2 ... 6, velocity: .init(amount: 0.5), wetness: 0.8
            ))]
        case .fineliner: Self.builtIn(.fineliner)
        case .fountainPen: Self.builtIn(.fountainPen)
        case .brushPen: Self.builtIn(.brushPen)
        case .marker: Self.builtIn(.marker)
        case .dashedPen: Self.builtIn(.dashedPen)
        case .dottedPen: Self.builtIn(.dottedPen)
        case .softPencil: Self.builtIn(.softPencil)
        case .chiselHighlighter:
            [brushStroke(.pen, width: 4, tilt: false, wave: 0), builtInStroke(.chiselHighlighter, wave: 3),
             builtInStroke(.chiselHighlighter, wave: 4)]
        }
    }

    /// A built-in brush on a handwriting-like wave and a loop, tilted as the Pencil sweeps.
    private static func builtIn(_ brush: BrushDescriptor) -> [Stroke] {
        [builtInStroke(brush, wave: 0), builtInStroke(brush, wave: 1), builtInStroke(brush, wave: 2)]
    }

    @MainActor func render() -> CGImage? {
        let doc = CanvasDocument(pageSize: Self.pageSize)
        for stroke in strokes {
            doc.add(stroke)
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return PageRenderer.image(of: doc.snapshot(), pixelWidth: Int(Self.pageSize.width) * 2) { ctx, size in
            ctx.setFillColor(white)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// A deterministic stroke: a wave across the page with pressure, altitude and azimuth sweeping along it.
/// `wave` picks one of a few shapes (0, 1 handwriting-like, 2 a loop, 3 a straight pass, 4 a vertical zigzag).
func brushStroke(_ brush: TestBrush, width: CGFloat, tilt: Bool, wave: Int) -> Stroke {
    let count = 90
    let points = (0 ..< count).map { i -> StrokePoint in
        let t = CGFloat(i) / CGFloat(count - 1)
        let location = switch wave {
        case 0: CGPoint(x: 20 + 260 * t, y: 60 + 25 * sin(t * 9))
        case 1: CGPoint(x: 20 + 260 * t, y: 105 + 18 * sin(t * 15 + 1))
        case 2: CGPoint(x: 150 + 90 * cos(t * 6) * (0.4 + 0.6 * t), y: 80 + 50 * sin(t * 6) * (0.4 + 0.6 * t))
        case 3: CGPoint(x: 15 + 270 * t, y: 64 + 2 * sin(t * 3))
        default: CGPoint(x: 60 + 180 * t, y: 80 + 60 * (abs((t * 6).truncatingRemainder(dividingBy: 2) - 1) - 0.5))
        }
        return StrokePoint(location: location,
                           force: 0.15 + 0.8 * (0.5 + 0.5 * sin(t * 7 + CGFloat(wave))),
                           altitude: (25 + 60 * (0.5 + 0.5 * cos(t * 5))) * .pi / 180,
                           azimuth: -.pi / 4 + 0.8 * sin(t * 4),
                           timestamp: Double(i) / 240)
    }
    let color = brush == .highlighter ? RGBA(r: 1, g: 0.85, b: 0.2) : RGBA(r: 0.12, g: 0.2, b: 0.55)
    return Stroke(id: UUID(), color: color, brush: brush.brush(width: width, tilt: tilt), points: points)
}

/// `brushStroke`'s path drawn with a built-in brush at its default width, as the canvas would with the
/// default Pressure & Tilt settings.
func builtInStroke(_ brush: BrushDescriptor, wave: Int) -> Stroke {
    var stroke = brushStroke(.pen, width: 4, tilt: true, wave: wave)
    stroke.brush = brush.personalized(width: brush.maxWidth,
                                      minimumWidthRatio: BrushDescriptor.neutralMinimumWidthRatio,
                                      pressureExponent: BrushDescriptor.neutralPressureExponent, tilt: true)
    if brush.blend == .multiply {
        stroke.color = RGBA(r: 1, g: 0.85, b: 0.2)
    }
    return stroke
}

extension Stroke {
    func with(_ brush: BrushDescriptor) -> Stroke {
        var stroke = self
        stroke.brush = brush
        return stroke
    }
}

// MARK: - Image helpers

let snapshotDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Snapshots", isDirectory: true)

struct ImageDiff {
    var maxChannelDelta: Int
    var differingPixels: Int
}

func rgbaBytes(_ image: CGImage) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: image.width * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

func compare(_ a: CGImage, _ b: CGImage) -> ImageDiff? {
    guard a.width == b.width, a.height == b.height, let da = rgbaBytes(a), let db = rgbaBytes(b) else { return nil }
    var diff = ImageDiff(maxChannelDelta: 0, differingPixels: 0)
    for p in stride(from: 0, to: da.count, by: 4) {
        var delta = 0
        for c in 0 ..< 4 {
            delta = max(delta, abs(Int(da[p + c]) - Int(db[p + c])))
        }
        if delta > 0 {
            diff.differingPixels += 1
            diff.maxChannelDelta = max(diff.maxChannelDelta, delta)
        }
    }
    return diff
}

func loadPNG(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
