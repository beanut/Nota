import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@MainActor
@Suite("Committed renderer: banded rendering")
struct CommittedRendererTests {
    private let pixels = CGSize(width: 600, height: 800)
    private let scale: CGFloat = 2
    private var bounds: CGRect {
        CGRect(x: 0, y: 0, width: pixels.width / scale, height: pixels.height / scale)
    }

    private let transform = ViewTransform(scale: 1.3, offset: CGPoint(x: 7.25, y: 11.5))

    /// Wavy strokes in every kind, crossing each other and the bands: pen, tilted pencil (textured, more
    /// than one alpha run), highlighter (multiply) and pixel eraser (destination-out).
    private func page(_ count: Int) -> [Stroke] {
        (0 ..< count).map { n in
            let tool: TestBrush = [.pen, .pencil, .highlighter, .pen, .pixelEraser][n % 5]
            let brush = tool.brush(width: tool == .highlighter ? 14 : 4, tilt: true)
            let y0 = CGFloat(n * 37 % 560) + 10, x0 = CGFloat(n * 53 % 120) + 5
            let points = (0 ..< 40).map { (i: Int) -> StrokePoint in
                let t = CGFloat(i)
                let location = CGPoint(x: x0 + t * 6, y: y0 + 9 * sin(CGFloat(i + n) * 0.7))
                let force: CGFloat = 0.3 + 0.6 * CGFloat(i % 7) / 7
                let altitude: CGFloat = 0.3 + CGFloat(i % 5) * 0.25
                return StrokePoint(location: location, force: force, altitude: altitude, azimuth: t * 0.2,
                                   timestamp: Double(i) / 240)
            }
            return Stroke(id: UUID(), color: RGBA.swatches[n % RGBA.swatches.count], brush: brush, points: points)
        }
    }

    private func render(_ strokes: [Stroke], parallel: Bool = true) throws -> CGContext {
        let ctx = try #require(CommittedRenderer.makeBitmap(pixelSize: pixels, scale: scale))
        let items = strokes.map {
            CommittedRenderer.Item(id: $0.id, brush: $0.brush, color: $0.color, geometry: nil, stroke: $0)
        }
        CommittedRenderer.render(items, into: ctx, bounds: bounds, transform: transform, parallel: parallel)
        return ctx
    }

    private func bytes(_ ctx: CGContext) -> [UInt8] {
        Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                  count: ctx.bytesPerRow * ctx.height))
    }

    @Test func bandsDrawWhatOneThreadDraws() throws {
        let strokes = page(CommittedRenderer.parallelThreshold * 2)
        let serial = try bytes(render(strokes, parallel: false))
        let banded = try bytes(render(strokes))
        #expect(serial.contains { $0 != 0 })
        // Moving each band's origin can round a coordinate differently in its last bit, so allow
        // antialiasing to differ by a step or two, but nothing anyone could see.
        var visible = 0
        for (a, b) in zip(serial, banded) where abs(Int(a) - Int(b)) > 3 {
            visible += 1
        }
        #expect(visible <= serial.count / 10000, "\(visible) bytes differ by more than 3")
    }
}
