import CoreGraphics
import Foundation
import UIKit

/// Raw Pencil input as the canvas received it, event by event, so it can be replayed through the same
/// live-ink code later. The benchmarks replay recordings (see `Tests/InkKitBenchmarks`); record one from
/// the editor's More menu › Record Pencil Input.
///
/// Each stroke keeps its events in arrival order:
/// - a **touch event**: the coalesced samples since the last event (about 2 per 120 Hz event at 240 Hz),
///   plus the predicted samples UIKit offered for the tail;
/// - an **estimate update**: refined force and tilt for samples sent earlier (`touchesEstimatedPropertiesUpdated`).
///
/// Samples are stored before the canvas drops near-duplicates, so a replay makes the same decisions.
/// Locations are in canvas space; times are seconds since the first sample of the recording.
public struct InkInputRecording: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public enum Source: String, Codable, Sendable {
        case pencil // Apple Pencil on an iPad
        case simulator // a finger or mouse in the simulator, with simulated pressure
        case synthetic // generated (see the benchmarks' `SyntheticPencil`)
    }

    public var version = Self.formatVersion
    public var source: Source
    /// Hardware model identifier, for example `iPad16,6`.
    public var device: String
    public var pageSize: PageSize
    public var strokes: [RecordedStroke] = []

    public init(source: Source, device: String, pageSize: PageSize) {
        self.source = source
        self.device = device
        self.pageSize = pageSize
    }

    public struct RecordedStroke: Codable, Sendable, Equatable {
        /// `pen`, `pencil`, `highlighter` or `pixelEraser`.
        public var tool: String
        /// sRGB red, green, blue and alpha.
        public var color: [Double]
        public var style: Style
        /// The stroke's whole brush. Recordings made before brushes were descriptors (NOT-16) don't have
        /// one; `tool` and `style` then pick a bundled brush and set its width and pressure response.
        public var brush: BrushDescriptor?
        /// Canvas-to-view scale while the stroke was drawn; the canvas drops samples closer than 0.3 view points.
        public var viewScale: Double
        public var events: [Event] = []

        public init(tool: String, color: [Double], style: Style, brush: BrushDescriptor? = nil, viewScale: Double,
                    events: [Event] = []) {
            self.tool = tool
            self.color = color
            self.style = style
            self.brush = brush
            self.viewScale = viewScale
            self.events = events
        }
    }

    public struct Style: Codable, Sendable, Equatable {
        public var width: Double
        public var minWidthRatio: Double
        public var pressureGamma: Double
        public var opacity: Double
        public var tiltEnabled: Bool
    }

    public struct Event: Codable, Sendable, Equatable {
        public var samples: [Sample]?
        public var predicted: [Sample]?
        public var updates: [Update]?

        public init(samples: [Sample]? = nil, predicted: [Sample]? = nil, updates: [Update]? = nil) {
            self.samples = samples
            self.predicted = predicted
            self.updates = updates
        }
    }

    /// One sample, encoded compactly as `[x, y, force, altitude, azimuth, time, pending]`.
    /// `pending` is 1 when force or tilt are estimates that a later `Update` refines.
    public struct Sample: Codable, Sendable, Equatable {
        public var x, y, force, altitude, azimuth, time: Double
        public var pending: Bool

        public init(x: Double, y: Double, force: Double, altitude: Double, azimuth: Double, time: Double,
                    pending: Bool) {
            self.x = x
            self.y = y
            self.force = force
            self.altitude = altitude
            self.azimuth = azimuth
            self.time = time
            self.pending = pending
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            x = try c.decode(Double.self)
            y = try c.decode(Double.self)
            force = try c.decode(Double.self)
            altitude = try c.decode(Double.self)
            azimuth = try c.decode(Double.self)
            time = try c.decode(Double.self)
            pending = try c.decodeIfPresent(Int.self) == 1
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(x.rounded(places: 3))
            try c.encode(y.rounded(places: 3))
            try c.encode(force.rounded(places: 4))
            try c.encode(altitude.rounded(places: 4))
            try c.encode(azimuth.rounded(places: 4))
            try c.encode(time.rounded(places: 5))
            try c.encode(pending ? 1 : 0)
        }
    }

    /// Refined values for the `sample`-th raw sample of the stroke (counting from 0, near-duplicates
    /// included), encoded as `[sample, force, altitude, azimuth, final]`. `final` is 1 when no further
    /// update will follow.
    public struct Update: Codable, Sendable, Equatable {
        public var sample: Int
        public var force, altitude, azimuth: Double
        public var final: Bool

        public init(sample: Int, force: Double, altitude: Double, azimuth: Double, final: Bool) {
            self.sample = sample
            self.force = force
            self.altitude = altitude
            self.azimuth = azimuth
            self.final = final
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            sample = try c.decode(Int.self)
            force = try c.decode(Double.self)
            altitude = try c.decode(Double.self)
            azimuth = try c.decode(Double.self)
            final = try c.decode(Int.self) == 1
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(sample)
            try c.encode(force.rounded(places: 4))
            try c.encode(altitude.rounded(places: 4))
            try c.encode(azimuth.rounded(places: 4))
            try c.encode(final ? 1 : 0)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> InkInputRecording {
        try JSONDecoder().decode(InkInputRecording.self, from: data)
    }
}

private extension Double {
    func rounded(places: Int) -> Double {
        let k = pow(10, Double(places))
        return (self * k).rounded() / k
    }
}

// MARK: - Conversions

extension InkInputRecording.Sample {
    init(_ p: StrokePoint, origin: TimeInterval, pending: Bool) {
        self.init(x: Double(p.location.x), y: Double(p.location.y), force: Double(p.force),
                  altitude: Double(p.altitude), azimuth: Double(p.azimuth), time: p.timestamp - origin,
                  pending: pending)
    }

    var point: StrokePoint {
        StrokePoint(location: CGPoint(x: x, y: y), force: force, altitude: altitude, azimuth: azimuth,
                    timestamp: time)
    }
}

extension InkInputRecording.RecordedStroke {
    init(_ stroke: Stroke, viewScale: CGFloat) {
        let c = stroke.color
        let b = stroke.brush
        self.init(tool: Self.toolName(for: b),
                  color: [c.r, c.g, c.b, c.a].map { Double($0) },
                  style: InkInputRecording.Style(width: Double(b.maxWidth),
                                                 minWidthRatio: Double(b.maxWidth > 0 ? b.size.lowerBound / b.maxWidth : 1),
                                                 pressureGamma: Double(b.pressure.exponent),
                                                 opacity: Double(b.opacity), tiltEnabled: b.tilt.enabled),
                  brush: b,
                  viewScale: Double(viewScale))
    }

    /// The legacy tool name closest to `brush`, for readers that don't know descriptors.
    static func toolName(for brush: BrushDescriptor) -> String {
        if brush.erases {
            return "pixelEraser"
        }
        if brush.blend == .multiply {
            return "highlighter"
        }
        return brush.usesPattern ? "pencil" : "pen"
    }

    /// The bundled brush for a legacy tool name (`pen` for an unknown one).
    static func bundledBrush(forTool tool: String) -> BrushDescriptor {
        switch tool {
        case "pencil": .pencil
        case "highlighter": .highlighter
        case "pixelEraser": .pixelEraser
        default: .pen
        }
    }

    /// An empty stroke with this stroke's colour and brush, ready to receive the samples.
    func makeStroke(id: UUID = UUID()) -> Stroke {
        let c = color + Array(repeating: 1, count: max(0, 4 - color.count))
        var brush: BrushDescriptor
        if let recorded = self.brush {
            brush = recorded
        } else {
            brush = Self.bundledBrush(forTool: tool).sized(style.width, minimumRatio: style.minWidthRatio)
            brush.pressure = .init(amount: 1, exponent: style.pressureGamma)
            brush.opacity = style.opacity
            brush.tilt.enabled = style.tiltEnabled
        }
        return Stroke(id: id, color: RGBA(r: c[0], g: c[1], b: c[2], a: c[3]), brush: brush, points: [])
    }
}

// MARK: - Recording

/// Collects what the canvas receives into an `InkInputRecording`. `CanvasView` feeds it while
/// `CanvasController.inputRecorder` is set.
@MainActor
final class InputRecorder {
    private(set) var recording: InkInputRecording
    private var strokeIndex: [UUID: Int] = [:]
    private var rawCount: [UUID: Int] = [:]
    private var buffer: [InkInputRecording.Sample] = []
    private var estimates: [NSNumber: (stroke: Int, sample: Int)] = [:]
    private var origin: TimeInterval?

    init() {
        #if targetEnvironment(simulator)
            let source = InkInputRecording.Source.simulator
        #else
            let source = InkInputRecording.Source.pencil
        #endif
        recording = InkInputRecording(source: source, device: Self.modelIdentifier, pageSize: .default)
    }

    func begin(_ stroke: Stroke, viewScale: CGFloat, pageSize: PageSize) {
        if recording.strokes.isEmpty {
            recording.pageSize = pageSize
        }
        strokeIndex[stroke.id] = recording.strokes.count
        rawCount[stroke.id] = 0
        buffer = []
        recording.strokes.append(InkInputRecording.RecordedStroke(stroke, viewScale: viewScale))
    }

    /// One coalesced sample of the current event, before the canvas filters near-duplicates.
    func sample(_ point: StrokePoint, strokeID: UUID, estimationKey: NSNumber?) {
        guard let index = strokeIndex[strokeID] else { return }
        let origin = origin ?? point.timestamp
        self.origin = origin
        let ordinal = rawCount[strokeID, default: 0]
        rawCount[strokeID] = ordinal + 1
        if let estimationKey {
            estimates[estimationKey] = (index, ordinal)
        }
        buffer.append(InkInputRecording.Sample(point, origin: origin, pending: estimationKey != nil))
    }

    func endEvent(strokeID: UUID, predicted: [StrokePoint]) {
        guard let index = strokeIndex[strokeID] else { return }
        let origin = origin ?? 0
        recording.strokes[index].events.append(InkInputRecording.Event(
            samples: buffer,
            predicted: predicted.isEmpty ? nil : predicted.map { .init($0, origin: origin, pending: false) }
        ))
        buffer = []
    }

    func update(estimationKey: NSNumber, force: CGFloat, altitude: CGFloat, azimuth: CGFloat, final: Bool) {
        guard let ref = estimates[estimationKey] else { return }
        if final {
            estimates[estimationKey] = nil
        }
        let update = InkInputRecording.Update(sample: ref.sample, force: Double(force), altitude: Double(altitude),
                                              azimuth: Double(azimuth), final: final)
        recording.strokes[ref.stroke].events.append(InkInputRecording.Event(updates: [update]))
    }

    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }
    }
}

// MARK: - Replay

/// Feeds recorded input through the canvas's live-ink path: `LiveStroke` builds the geometry and a
/// `LiveInkView` of the given size draws its tiles, event by event, as `CanvasView` would.
@MainActor
final class InputReplayer {
    let liveView: LiveInkView
    private var current: LiveStroke?

    init(viewSize: CGSize, transform: ViewTransform, displayScale: CGFloat = 2) {
        liveView = LiveInkView(frame: CGRect(origin: .zero, size: viewSize))
        liveView.traitOverrides.displayScale = displayScale
        liveView.layoutIfNeeded()
        liveView.entries = { [weak self] in
            self?.current.map { [LiveInkView.Entry(stroke: $0, previewFill: nil)] } ?? []
        }
        liveView.settle(at: transform)
    }

    /// Replays one stroke and returns it as the canvas would commit it. `eachEvent` runs after every event
    /// has been ingested and its tiles drawn.
    @discardableResult
    func replay(_ recorded: InkInputRecording.RecordedStroke, transform: ViewTransform,
                eachEvent: (Int) -> Void = { _ in }) -> Stroke {
        liveView.settle(at: transform)
        let live = LiveStroke(stroke: recorded.makeStroke())
        current = live
        defer {
            current = nil
            liveView.invalidateAll() // clears the tiles, as committing does
        }
        let minSpacing = 0.3 / transform.scale
        var indexOfSample: [Int?] = []

        for (n, event) in recorded.events.enumerated() {
            var dirty = CGRect.null
            if let samples = event.samples {
                for sample in samples {
                    let index = live.append(sample.point, minSpacing: minSpacing)
                    indexOfSample.append(index)
                    if let index, sample.pending {
                        live.unsettledPoints.insert(index)
                    }
                }
                dirty = live.advance(predicted: event.predicted?.map(\.point) ?? [])
            }
            if let updates = event.updates {
                dirty = dirty.union(apply(updates, to: live, indexOfSample: indexOfSample))
            }
            liveView.invalidate(canvasRect: dirty)
            liveView.displayPendingTiles()
            eachEvent(n)
        }
        return live.stroke
    }

    /// Mirrors `CanvasView.touchesEstimatedPropertiesUpdated` for the stroke under the Pencil.
    private func apply(_ updates: [InkInputRecording.Update], to live: LiveStroke, indexOfSample: [Int?]) -> CGRect {
        var dirty = CGRect.null
        var touchesTail = false
        for update in updates {
            guard indexOfSample.indices.contains(update.sample), let index = indexOfSample[update.sample],
                  live.stroke.points.indices.contains(index) else { continue }
            live.stroke.points[index].force = update.force
            live.stroke.points[index].altitude = update.altitude
            live.stroke.points[index].azimuth = update.azimuth
            let r = live.refreshPoint(index)
            liveView.geometryChanged(of: live, fromSegment: index - 1, canvasRect: r.dirty)
            dirty = dirty.union(r.dirty)
            touchesTail = touchesTail || r.touchesTail
            if update.final {
                live.unsettledPoints.remove(index)
            }
        }
        if touchesTail {
            dirty = dirty.union(live.rebuildTail(predicted: live.lastPredicted))
        }
        return dirty
    }
}

extension InkInputRecording.RecordedStroke {
    /// The stroke the canvas would commit from this input, without drawing anything: every sample through
    /// `LiveStroke.append`, then every refinement applied.
    func committedStroke(id: UUID = UUID()) -> Stroke {
        let live = LiveStroke(stroke: makeStroke(id: id))
        let minSpacing = 0.3 / max(viewScale, 0.01)
        var indexOfSample: [Int?] = []
        for event in events {
            for sample in event.samples ?? [] {
                indexOfSample.append(live.append(sample.point, minSpacing: minSpacing))
            }
            for update in event.updates ?? [] {
                guard indexOfSample.indices.contains(update.sample), let index = indexOfSample[update.sample]
                else { continue }
                live.stroke.points[index].force = update.force
                live.stroke.points[index].altitude = update.altitude
                live.stroke.points[index].azimuth = update.azimuth
            }
        }
        return live.stroke
    }
}
