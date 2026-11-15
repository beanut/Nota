import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Brush descriptors")
struct BrushDescriptorTests {
    // MARK: Ranges and clamping

    @Test func bundledBrushesAreInRange() {
        for brush in BrushDescriptor.bundled {
            #expect(brush.clamped() == brush, "\(brush.name)")
        }
        #expect(Set(BrushDescriptor.bundled.map(\.id)).count == BrushDescriptor.bundled.count)
    }

    @Test func bundledBrushesPickTheirRenderPath() {
        let stamped: Set<UUID> = [BrushDescriptor.dashedPen.id, BrushDescriptor.dottedPen.id]
        #expect(BrushDescriptor.bundled.allSatisfy { ($0.renderPath == .stamp) == stamped.contains($0.id) })
        #expect(dryBrush.renderPath == .stamp)
        var dashed = BrushDescriptor.pen
        dashed.dash = .init(on: 2, off: 1)
        #expect(dashed.renderPath == .stamp && dashed.measuresDistance)
        var spaced = BrushDescriptor.pen
        spaced.spacing = 0.5
        #expect(spaced.renderPath == .stamp)
        #expect(BrushDescriptor.pixelEraser.erases && !BrushDescriptor.pen.erases)
    }

    @Test func clampingPullsEveryParameterIntoRange() {
        var b = BrushDescriptor.pen
        b.name = String(repeating: "x", count: 500)
        b.tip = .ellipse(aspect: 0, angle: 7)
        b.size = 0 ... 5000
        b.pressure = .init(amount: 3, exponent: -2)
        b.pressureOpacity = .init(amount: .nan, exponent: .infinity)
        b.tilt = .init(startAltitude: 120, fullAltitude: 200, length: 99, breadth: -1, opacityLoss: 2,
                       contactShift: .nan)
        b.velocity = .init(amount: -1, exponent: 0)
        b.taper = .init(startLength: -5, endLength: 1e9, minimumScale: 4)
        b.smoothing = 3
        b.texture = .bristle(count: 1000, spread: 0)
        b.spacing = 0.01
        b.jitter = .init(size: 9, angle: -1, scatter: 9, opacity: .nan)
        b.dash = .init(on: 0, off: 99)
        b.wetness = -0.5
        b.opacity = 0
        let c = b.clamped()
        #expect(c.name.count == BrushDescriptor.maxNameLength)
        #expect(c.tip == .ellipse(aspect: 0.05, angle: atan2(sin(7), cos(7))))
        #expect(c.size == 0 ... 1000)
        #expect(c.pressure == .init(amount: 1, exponent: 0.1))
        #expect(c.pressureOpacity == .init(amount: 0, exponent: 5)) // NaN takes the fallback; ∞ the maximum
        #expect(c.tilt.startAltitude == 89 && c.tilt.fullAltitude == 88 && c.tilt.length == 8 && c.tilt.breadth == 0)
        #expect(c.tilt.opacityLoss == 1 && c.tilt.contactShift == 0.35)
        #expect(c.velocity == .init(amount: 0, exponent: 0.1))
        #expect(c.taper == .init(startLength: 0, endLength: 500, minimumScale: 1))
        #expect(c.smoothing == 0.95)
        #expect(c.texture == .bristle(count: 64, spread: 0.1))
        #expect(c.spacing == 0) // under half the minimum: continuous
        #expect(c.jitter == .init(size: 1, angle: 0, scatter: 2, opacity: 0))
        #expect(c.dash == .init(on: 0.05, off: 50))
        #expect(c.wetness == 0 && c.opacity == 0.02)
        #expect(c.clamped() == c)
    }

    // MARK: JSON

    @Test func bundledBrushesRoundTripThroughJSON() throws {
        for brush in BrushDescriptor.bundled + [dryBrush, calligraphy] {
            let decoded = try BrushDescriptor(json: brush.jsonData())
            #expect(decoded == brush, "\(brush.name)")
            #expect(try decoded.jsonData() == brush.jsonData())
        }
    }

    /// Whatever the JSON says, decoding gives a clamped brush that draws.
    @Test func solidBrushesLeaveTheDashOutOfTheirJSON() throws {
        let solid = try #require(JSONSerialization.jsonObject(with: BrushDescriptor.pen.jsonData()) as? [String: Any])
        #expect(solid["dash"] == nil)
        let dashed = try #require(JSONSerialization.jsonObject(with: BrushDescriptor.dashedPen.jsonData())
            as? [String: Any])
        #expect(dashed["dash"] as? [String: Double] == ["on": 3, "off": 2.5])
    }

    @Test(arguments: [
        "{}",
        #"{"size": [9, 2]}"#,
        #"{"size": [-4, -1], "opacity": -3, "spacing": 1e300}"#,
        #"{"size": "wide", "tip": "star", "texture": {"glitter": {}}, "blend": "screen"}"#,
        #"{"tip": {"ellipse": {"aspect": 40}}, "tilt": {"enabled": false}}"#,
        #"{"texture": {"bristle": {"count": -7, "spread": 99}}, "jitter": {"scatter": 1e9}}"#,
        #"{"texture": {"grain": {"scale": 0, "seed": 4294967295}}, "spacing": 0.001}"#,
        #"{"pressure": {"exponent": 1e-9}, "velocity": {"amount": 1}, "wetness": 9, "smoothing": -1}"#,
        #"{"taper": {"startLength": 1e9, "endLength": 1e9, "minimumScale": -1}, "size": [0, 0]}"#,
        #"{"id": 7, "name": ["not", "a", "name"], "pressureOpacity": null, "tilt": {"fullAltitude": 90}}"#
    ])
    func arbitraryJSONDecodesToADrawableBrush(_ json: String) throws {
        let brush = try BrushDescriptor(json: Data(json.utf8))
        #expect(brush.clamped() == brush)
        let geometry = StrokeRenderer.geometry(for: wave(brush))
        #expect(!geometry.runs.isEmpty)
        #expect(!geometry.bounds.isNull && geometry.bounds.width.isFinite && geometry.bounds.height.isFinite)
    }

    @Test func partialObjectsKeepTheirDefaults() throws {
        let brush = try BrushDescriptor(json: Data(#"{"name": "Flat", "tilt": {"enabled": false}}"#.utf8))
        #expect(brush.name == "Flat")
        #expect(!brush.tilt.enabled && brush.tilt.length == BrushDescriptor.TiltResponse.standard.length)
        #expect(brush.size == BrushDescriptor.pen.size && brush.pressure == BrushDescriptor.pen.pressure)
    }

    /// Done-when for NOT-16: editing a descriptor's JSON changes the stroke, with no code involved.
    @Test func editingTheJSONChangesTheStroke() throws {
        var object = try #require(JSONSerialization.jsonObject(with: BrushDescriptor.pen.jsonData()) as? [String: Any])
        let pen = StrokeRenderer.geometry(for: wave(.pen))

        object["size"] = [12, 12]
        let wide = try BrushDescriptor(json: JSONSerialization.data(withJSONObject: object))
        #expect(StrokeRenderer.geometry(for: wave(wide)).bounds.height > pen.bounds.height + 6)

        object["size"] = [1, 4]
        object["opacity"] = 0.5
        object["tilt"] = ["enabled": false] // tilt shading would lighten it further
        let light = try BrushDescriptor(json: JSONSerialization.data(withJSONObject: object))
        #expect(StrokeRenderer.geometry(for: wave(light)).runs.allSatisfy { abs($0.alpha - 0.5) < 0.02 })

        object["opacity"] = 1
        object["spacing"] = 1.5
        let dotted = try BrushDescriptor(json: JSONSerialization.data(withJSONObject: object))
        #expect(dotted.renderPath == .stamp)
        #expect(StrokeRenderer.hulls(for: wave(dotted).points, brush: dotted).allSatisfy { $0.polygon.count > 2 })

        object["blend"] = "destinationOut"
        #expect(try BrushDescriptor(json: JSONSerialization.data(withJSONObject: object)).erases)
    }

    // MARK: Nib model

    @Test func taperNarrowsBothEnds() {
        var tapered = BrushDescriptor.pen.sized(8, minimumRatio: 1)
        tapered.tilt = .off
        tapered.taper = .init(startLength: 40, endLength: 40, minimumScale: 0.1)
        let stroke = wave(tapered, count: 120)
        let context = StrokeContext(finished: stroke.points, brush: tapered)
        func width(at k: Int) -> CGFloat {
            StrokeRenderer.tip(for: stroke.points[k], brush: tapered, nib: context.nib(at: k, in: stroke.points)).major
        }
        #expect(width(at: 0) < 0.5)
        #expect(abs(width(at: 60) - 4) < 1e-9)
        #expect(width(at: 119) < 0.5)
    }

    @Test func velocityThinsFastStrokes() {
        var brush = BrushDescriptor.pen.sized(8, minimumRatio: 1)
        brush.velocity = .init(amount: 0.6)
        let slow = wave(brush, count: 60, duration: 2), fast = wave(brush, count: 60, duration: 0.05)
        func width(_ stroke: Stroke) -> CGFloat {
            let context = StrokeContext(finished: stroke.points, brush: brush)
            return StrokeRenderer.tip(for: stroke.points[30], brush: brush,
                                      nib: context.nib(at: 30, in: stroke.points)).major
        }
        #expect(width(fast) < width(slow) * 0.6)
    }

    @Test func calligraphyNibKeepsItsAngle() {
        let tip = StrokeRenderer.tip(for: StrokePoint(location: .zero, force: 1, altitude: .pi / 2, azimuth: 2,
                                                      timestamp: 0), brush: calligraphy)
        #expect(tip.angle == 0.7)
        #expect(abs(tip.minor / tip.major - 0.2) < 1e-9)
    }

    @Test func smoothingPullsSamplesTowardTheStroke() {
        var brush = BrushDescriptor.pen
        brush.smoothing = 0.5
        let live = LiveStroke(stroke: Stroke(id: UUID(), color: RGBA.swatches[0], brush: brush, points: []))
        live.append(StrokePoint(location: .zero, force: 0.5, altitude: 1, azimuth: 0, timestamp: 0), minSpacing: 0)
        live.append(StrokePoint(location: CGPoint(x: 10, y: 0), force: 0.5, altitude: 1, azimuth: 0, timestamp: 0.01),
                    minSpacing: 0)
        #expect(live.stroke.points[1].location == CGPoint(x: 5, y: 0))
    }

    // MARK: Live and committed geometry agree

    /// The live stroke (finalized segments, tail, end taper applied on `finish()`) must build exactly the
    /// geometry a full rebuild does, or ink would shift when the page re-renders.
    @Test(arguments: ["tapered", "dry brush", "calligraphy", "wet", "Fountain Pen", "Brush Pen", "Dashed",
                      "Dotted", "Soft Pencil", "Crayon", "Marker", "Chisel Highlighter"])
    func liveGeometryMatchesTheFullRebuild(_ name: String) {
        let builtIn = BrushDescriptor.bundled.first { $0.name == name }
        let brush: BrushDescriptor = switch name {
        case _ where builtIn != nil: builtIn ?? .pen
        case "tapered": {
                var b = BrushDescriptor.pencil.sized(5, minimumRatio: 0.3)
                b.taper = .init(startLength: 25, endLength: 30)
                return b
            }()
        case "dry brush": dryBrush
        case "calligraphy": calligraphy
        default: {
                var b = BrushDescriptor.pen.sized(6, minimumRatio: 0.2)
                b.velocity = .init(amount: 0.5, exponent: 2)
                b.wetness = 0.7
                return b
            }()
        }
        let stroke = wave(brush, count: 150)
        let live = LiveStroke(stroke: Stroke(id: stroke.id, color: stroke.color, brush: brush, points: []))
        for (k, p) in stroke.points.enumerated() {
            live.append(p, minSpacing: 0)
            // A couple of predicted samples, as the canvas offers them.
            let predicted = stroke.points[min(k + 1, stroke.points.count - 1)...].prefix(2).map {
                var q = $0
                q.location.x += 0.7
                return q
            }
            _ = live.advance(predicted: Array(predicted))
        }
        live.finish()
        _ = live.geometry()
        let points = live.stroke.points
        let context = StrokeContext(finished: points, brush: brush)
        #expect(live.finalizedCount >= points.count - 3)
        for segment in 0 ..< live.finalizedCount {
            let expected = StrokeRenderer.segmentHulls(points, segment: segment, context: context,
                                                       leadingStamp: segment % LiveStroke.chunkSize == 0)
            let built = live.finalized[segment]
            #expect(built.count == expected.count && zip(built, expected).allSatisfy {
                $0.bounds == $1.bounds && $0.alpha == $1.alpha
            }, "segment \(segment)")
        }
        // The tail starts with a stamp of its own (it's filled apart from the last chunk), so compare its extent.
        let full = StrokeRenderer.hulls(for: points, brush: brush).reduce(CGRect.null) { $0.union($1.bounds) }
        let incremental = live.allHulls.reduce(CGRect.null) { $0.union($1.bounds) }
        #expect(abs(full.minX - incremental.minX) < 1e-6 && abs(full.maxX - incremental.maxX) < 1e-6)
        #expect(abs(full.minY - incremental.minY) < 1e-6 && abs(full.maxY - incremental.maxY) < 1e-6)
    }

    @Test func stampsAreTheSameEveryTime() {
        let stroke = wave(dryBrush)
        let a = StrokeRenderer.hulls(for: stroke.points, brush: dryBrush)
        let b = StrokeRenderer.hulls(for: stroke.points, brush: dryBrush)
        #expect(a.count == b.count && zip(a, b).allSatisfy { $0.polygon == $1.polygon })
        var reseeded = dryBrush
        reseeded.jitter.seed += 1
        let c = StrokeRenderer.hulls(for: stroke.points, brush: reseeded)
        #expect(!zip(a, c).allSatisfy { $0.polygon == $1.polygon })
    }

    @Test func dashesLeaveGapsAtTheirPeriod() {
        // A straight 300-point line, so arc length is x.
        let points = (0 ..< 61).map { i in
            StrokePoint(location: CGPoint(x: CGFloat(i) * 5, y: 50), force: 1, altitude: .pi / 2, azimuth: 0,
                        timestamp: Double(i) / 240)
        }
        let brush = BrushDescriptor.dashedPen.sized(4, minimumRatio: 1)
        var solid = brush
        solid.dash = .none
        solid.spacing = 0.15 // the dashed brush's stamp spacing, without the gaps
        let dashed = StrokeRenderer.hulls(for: points, brush: brush)
        #expect(dashed.count < StrokeRenderer.hulls(for: points, brush: solid).count)
        // Every stamp centre lies in an "on" stretch: on 3 × 4 = 12 pt, period (3 + 2.5) × 4 = 22 pt.
        for hull in dashed {
            let x = hull.bounds.midX.truncatingRemainder(dividingBy: 22)
            #expect(x <= 12 + 0.5, "stamp at \(hull.bounds.midX)")
        }
        // And every period has ink: no dash is lost.
        let periods = Set(dashed.map { Int($0.bounds.midX / 22) })
        #expect(periods == Set(0 ... 13))
    }

    // MARK: Storage

    @Test func inkFileKeepsCustomDescriptors() throws {
        let strokes = [wave(dryBrush), wave(calligraphy), wave(.pencil), wave(dryBrush)]
        let decoded = try InkPageFile(data: InkPageFile(pageID: UUID(), strokes: strokes).encoded())
        #expect(decoded.strokes.map(\.brush) == strokes.map(\.brush))
    }

    @Test func recordingsKeepTheBrushAndReadLegacyStyles() {
        let recorded = InkInputRecording.RecordedStroke(wave(calligraphy), viewScale: 1)
        #expect(recorded.makeStroke().brush == calligraphy)
        #expect(recorded.tool == "pen")

        let legacy = InkInputRecording.RecordedStroke(
            tool: "highlighter", color: [1, 1, 0, 1],
            style: .init(width: 20, minWidthRatio: 0.25, pressureGamma: 0.6, opacity: 0.38, tiltEnabled: true),
            viewScale: 1
        )
        let brush = legacy.makeStroke().brush
        #expect(brush.id == BrushDescriptor.highlighter.id && brush.blend == .multiply)
        #expect(brush.size == 5 ... 20 && brush.pressure.exponent == 0.6 && brush.opacity == 0.38)
    }
}

// MARK: - Fixtures

/// A bristly, jittery stamp brush.
private let dryBrush = BrushDescriptor(name: "Dry Brush", size: 4 ... 14, tilt: .off,
                                       texture: .bristle(count: 12, spread: 0.9), spacing: 0.3,
                                       jitter: .init(size: 0.3, angle: 0.2, scatter: 0.1, opacity: 0.4, seed: 7))

/// A flat nib at a fixed angle with tapered ends.
private let calligraphy = BrushDescriptor(name: "Italic", tip: .ellipse(aspect: 0.2, angle: 0.7), size: 2 ... 9,
                                          tilt: .off, taper: .init(startLength: 12, endLength: 20))

/// A wavy stroke over `duration` seconds, with pressure varying along it.
private func wave(_ brush: BrushDescriptor, count: Int = 80, duration: Double = 0.4) -> Stroke {
    let points = (0 ..< count).map { i -> StrokePoint in
        let t = CGFloat(i) / CGFloat(count - 1)
        return StrokePoint(location: CGPoint(x: 20 + 240 * t, y: 80 + 30 * sin(t * 8)),
                           force: 0.3 + 0.6 * (0.5 + 0.5 * sin(t * 5)),
                           altitude: 0.5 + 0.8 * t, azimuth: -0.6 + t,
                           timestamp: duration * Double(t))
    }
    return Stroke(id: UUID(), color: RGBA.swatches[0], brush: brush, points: points)
}
