import CoreGraphics
import Foundation
@testable import InkKit

/// Generates Pencil-shaped input for the benchmark fixture until real recordings from an iPad replace it.
///
/// It reproduces what the replay path is sensitive to rather than any one person's handwriting:
/// - 240 Hz samples delivered as coalesced batches on 120 Hz events (usually 2, sometimes 1 or 3);
/// - 2 predicted samples per event, extrapolated from the latest velocity;
/// - force and tilt sent as estimates, refined two events later (and after the stroke ends);
/// - cursive-like words with loops and speed changes, dots and crossbars, a highlighter pass and a long,
///   tilted pencil shading scribble (the costliest case: alpha varies along the stroke).
///
/// Deterministic: the same seed always gives the same recording.
struct SyntheticPencil {
    static let sampleRate: Double = 240
    static let eventRate: Double = 120

    private var rng: SplitMix64
    private var clock: Double = 0
    private var recording: InkInputRecording
    private let viewScale: Double

    init(seed: UInt64, pageSize: PageSize = .letter, viewScale: Double) {
        rng = SplitMix64(seed: seed)
        self.viewScale = viewScale
        recording = InkInputRecording(source: .synthetic, device: "synthetic", pageSize: pageSize)
    }

    /// About a quarter page of handwriting: 5 lines of words with dots and crossbars, a highlighted line and a
    /// shading scribble.
    static func handwriting(seed: UInt64 = 0x14B1D, viewScale: Double) -> InkInputRecording {
        var pencil = SyntheticPencil(seed: seed, viewScale: viewScale)
        let pen = pencil.style(width: 4, opacity: 1)
        let pencilStyle = pencil.style(width: 3, opacity: 0.85)
        let blackPen = Brush(tool: "pen", color: [0.11, 0.11, 0.12, 1], style: pen)
        let bluePen = Brush(tool: "pen", color: [0.16, 0.33, 0.8, 1], style: pen)
        let graphite = Brush(tool: "pencil", color: [0.25, 0.25, 0.27, 1], style: pencilStyle)
        for line in 0 ..< 5 {
            let baseline = 96 + Double(line) * 36
            var x = 56.0
            let brush = line == 3 ? graphite : (line.isMultiple(of: 3) ? bluePen : blackPen)
            while x < 470 {
                let letters = pencil.rng.int(in: 2 ... 9)
                let width = pencil.word(at: CGPoint(x: x, y: baseline), letters: letters, brush: brush)
                if pencil.rng.unit() < 0.45 {
                    pencil.dot(at: CGPoint(x: x + width * pencil.rng.unit(), y: baseline - 22), brush: brush)
                }
                if pencil.rng.unit() < 0.3 {
                    pencil.bar(from: CGPoint(x: x + width * 0.3, y: baseline - 14), length: 14, brush: brush)
                }
                x += width + pencil.rng.double(in: 10 ... 18)
            }
        }
        let highlighter = Brush(tool: "highlighter", color: [1, 0.85, 0.2, 1],
                                style: pencil.style(width: 22, opacity: 0.38))
        pencil.bar(from: CGPoint(x: 52, y: 96 + 36 - 6), length: 300, brush: highlighter, duration: 0.9)
        pencil.scribble(in: CGRect(x: 360, y: 270, width: 140, height: 90), duration: 4, brush: graphite)
        return pencil.recording
    }

    private struct Brush {
        let tool: String
        let color: [Double]
        let style: InkInputRecording.Style
    }

    private struct Truth {
        let force: Double
        let altitude: Double
        let azimuth: Double
    }

    private func style(width: Double, opacity: Double) -> InkInputRecording.Style {
        InkInputRecording.Style(width: width, minWidthRatio: 0.25, pressureGamma: 0.6, opacity: opacity,
                                tiltEnabled: true)
    }

    // MARK: Shapes

    /// A cursive word: loops from x doubling back on the sine, humps of mixed heights. Returns its width.
    private mutating func word(at origin: CGPoint, letters: Int, brush: Brush) -> Double {
        let advance = 9.0
        let heights = (0 ... letters).map { _ in rng.unit() < 0.2 ? rng.double(in: 16 ... 20) : rng.double(in: 7 ... 10) }
        let lettersPerSecond = rng.double(in: 4.5 ... 6.5)
        var u = 0.0
        var path: [(CGPoint, Double)] = [] // location, speed factor
        while u <= Double(letters) {
            let h = heights[min(Int(u), letters)]
            let x = origin.x + advance * u - 3.6 * sin(2 * .pi * u)
            let y = origin.y - h * (0.5 - 0.5 * cos(2 * .pi * u))
            let slow = 0.65 + 0.55 * abs(sin(.pi * u)) // slower at the turns
            path.append((CGPoint(x: x + rng.double(in: -0.04 ... 0.04), y: y + rng.double(in: -0.04 ... 0.04)), slow))
            u += lettersPerSecond / Self.sampleRate * slow
        }
        emit(path.map(\.0), brush: brush, pressure: rng.double(in: 0.42 ... 0.68),
             altitude: rng.double(in: 0.85 ... 1.05))
        return advance * Double(letters)
    }

    private mutating func dot(at p: CGPoint, brush: Brush) {
        let n = rng.int(in: 5 ... 12)
        let points = (0 ..< n).map { i in CGPoint(x: p.x + Double(i) * 0.12, y: p.y + Double(i) * 0.08) }
        emit(points, brush: brush, pressure: 0.6, altitude: 1.0)
    }

    private mutating func bar(from p: CGPoint, length: Double, brush: Brush, duration: Double = 0.07) {
        let n = max(2, Int(duration * Self.sampleRate))
        let points = (0 ..< n).map { i -> CGPoint in
            let t = Double(i) / Double(n - 1)
            return CGPoint(x: p.x + length * t, y: p.y - 1.5 * sin(.pi * t) + rng.double(in: -0.05 ... 0.05))
        }
        emit(points, brush: brush, pressure: 0.55, altitude: 0.95)
    }

    /// Back-and-forth shading with the Pencil tilted low, drifting down the box.
    private mutating func scribble(in box: CGRect, duration: Double, brush: Brush) {
        let n = Int(duration * Self.sampleRate)
        let strokesPerSecond = 7.0
        let points = (0 ..< n).map { i -> CGPoint in
            let t = Double(i) / Self.sampleRate
            let across = 0.5 - 0.5 * cos(2 * .pi * strokesPerSecond * t / 2)
            return CGPoint(x: box.minX + box.width * across,
                           y: box.minY + box.height * (t / duration) + 6 * sin(2 * .pi * strokesPerSecond * t))
        }
        emit(points, brush: brush, pressure: 0.5, altitude: 0.45)
    }

    // MARK: Events

    /// Turns a path sampled at 240 Hz into touch events, predictions and estimate updates.
    private mutating func emit(_ path: [CGPoint], brush: Brush, pressure: Double, altitude: Double) {
        guard !path.isEmpty else { return }
        clock += rng.double(in: 0.15 ... 0.4) // pen lifted between strokes
        let start = clock
        let azimuth = -0.75 + rng.double(in: -0.1 ... 0.1)
        let n = path.count
        var truth: [Truth] = []
        var samples: [InkInputRecording.Sample] = []
        for (i, p) in path.enumerated() {
            let t = Double(i) / Self.sampleRate
            let rampIn = smoothstep(min(t / 0.03, 1))
            let rampOut = smoothstep(min(Double(n - 1 - i) / Self.sampleRate / 0.04, 1))
            let force = min(max(pressure * (0.85 + 0.15 * sin(t * 9)) * rampIn * rampOut
                    + rng.double(in: -0.01 ... 0.01), 0.03), 1)
            let alt = altitude + 0.05 * sin(t * 2.3)
            let az = azimuth + 0.06 * sin(t * 1.7)
            truth.append(Truth(force: force, altitude: alt, azimuth: az))
            // The first report is an estimate, off by a little.
            samples.append(InkInputRecording.Sample(
                x: Double(p.x), y: Double(p.y), force: min(max(force + rng.double(in: -0.04 ... 0.04), 0), 1),
                altitude: alt + rng.double(in: -0.03 ... 0.03), azimuth: az, time: start + t, pending: true
            ))
        }
        clock = start + Double(n) / Self.sampleRate

        var stroke = InkInputRecording.RecordedStroke(tool: brush.tool, color: brush.color, style: brush.style,
                                                      viewScale: viewScale)
        var batches: [Range<Int>] = []
        var i = 0
        while i < n {
            let r = rng.unit()
            let size = r < 0.1 ? 1 : (r < 0.2 ? 3 : 2)
            batches.append(i ..< min(i + size, n))
            i += size
        }
        var unrefined: [[Int]] = [] // sample indices per event, waiting for their update
        func update(_ indices: [Int]) -> InkInputRecording.Event {
            InkInputRecording.Event(updates: indices.map { k in
                InkInputRecording.Update(sample: k, force: truth[k].force, altitude: truth[k].altitude,
                                         azimuth: truth[k].azimuth, final: true)
            })
        }
        for (e, batch) in batches.enumerated() {
            let last = e == batches.count - 1
            var predicted: [InkInputRecording.Sample]?
            if !last, batch.upperBound >= 2 {
                let a = samples[batch.upperBound - 2], b = samples[batch.upperBound - 1]
                predicted = (1 ... 2).map { k in
                    let s = Double(k) * 1.6 // UIKit predicts a little over a sample interval ahead per step
                    return InkInputRecording.Sample(x: b.x + (b.x - a.x) * s, y: b.y + (b.y - a.y) * s,
                                                    force: b.force, altitude: b.altitude, azimuth: b.azimuth,
                                                    time: b.time + s / Self.sampleRate, pending: false)
                }
            }
            stroke.events.append(InkInputRecording.Event(samples: Array(samples[batch]), predicted: predicted))
            unrefined.append(Array(batch))
            if unrefined.count > 2 {
                stroke.events.append(update(unrefined.removeFirst()))
            }
        }
        for indices in unrefined {
            stroke.events.append(update(indices))
        }
        recording.strokes.append(stroke)
    }

    private func smoothstep(_ x: Double) -> Double {
        x * x * (3 - 2 * x)
    }
}

/// Small, fast, seedable generator, so the fixture doesn't depend on the platform's random source.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
