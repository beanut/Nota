import CoreGraphics
import Foundation
@testable import InkKit
import UIKit
import XCTest

/// Shared setup for the ink benchmarks: the device being modelled, the input corpus, timing, memory and
/// the results file the nightly job compares against its baseline.
enum Bench {
    /// iPad Pro 13-inch in portrait, in points, at 2×: the largest screen InkKit draws on.
    static let screen = CGSize(width: 1032, height: 1376)
    static let displayScale: CGFloat = 2
    static var screenBounds: CGRect {
        CGRect(origin: .zero, size: screen)
    }

    /// The committed bitmap's size for `screen`.
    static var pixelSize: CGSize {
        CGSize(width: screen.width * displayScale, height: screen.height * displayScale)
    }

    /// Budgets only hold for optimized code; a Debug build still runs and reports, but asserts nothing.
    static var optimized: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }

    /// The page fitted to the screen as the editor shows it.
    static func fittedTransform(for page: PageSize) -> ViewTransform {
        ViewTransform.fitting(page: page.bounds, in: screenBounds, insets: CanvasController.defaultPageMargins)
    }

    /// `zoom` × the fitted scale, with `canvasPoint` in the middle of the screen.
    static func zoomedTransform(for page: PageSize, zoom: CGFloat, centredOn canvasPoint: CGPoint) -> ViewTransform {
        let scale = fittedTransform(for: page).scale * zoom
        return ViewTransform(scale: scale, offset: CGPoint(x: screen.width / 2 - canvasPoint.x * scale,
                                                           y: screen.height / 2 - canvasPoint.y * scale))
    }

    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(now() - start) / 1_000_000
    }

    /// `footprint()` after returning every free malloc page to the system: the starting point for a
    /// memory measurement that doesn't depend on which tests ran before it.
    static func settledFootprint() -> UInt64 {
        malloc_zone_pressure_relief(nil, 0)
        return footprint()
    }

    /// The bytes malloc has handed out and not had back: unlike the footprint, it doesn't count freed memory
    /// malloc still holds, nor lose memory freed by work done before, so it measures what a structure keeps.
    static func heapInUse() -> UInt64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt64(stats.size_in_use)
    }

    /// The process's physical footprint (what jetsam counts), in bytes.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Measured iterations for the quick benchmarks. Page-level ones take seconds each and run fewer.
    static let iterations = 10

    static var measureOptions: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        return options
    }
}

/// Order statistics of a list of samples.
struct Stats {
    let count: Int
    let median: Double
    let p95: Double
    let p99: Double
    let max: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        func quantile(_ q: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
        }
        median = quantile(0.5)
        p95 = quantile(0.95)
        p99 = quantile(0.99)
        max = sorted.last ?? 0
    }
}

// MARK: - Corpus

/// Every recording in `Fixtures/` (`*.inkrec.json`), and pages tiled from their strokes.
@MainActor
final class Corpus {
    static let shared = Corpus()

    let recordings: [InkInputRecording]
    /// Every recorded stroke, in recording order.
    let recordedStrokes: [InkInputRecording.RecordedStroke]
    /// What the canvas commits for each recorded stroke.
    let strokes: [Stroke]
    let pageSize: PageSize

    private init() {
        let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory ?? URL(fileURLWithPath: "/dev/null"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        recordings = files.filter { $0.lastPathComponent.hasSuffix(".inkrec.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? InkInputRecording.decode(Data(contentsOf: $0)) }
        recordedStrokes = recordings.flatMap(\.strokes)
        strokes = recordedStrokes.map { $0.committedStroke() }
        pageSize = recordings.first?.pageSize ?? .letter
    }

    var sampleCount: Int {
        recordedStrokes.reduce(0) { $0 + $1.events.reduce(0) { $0 + ($1.samples?.count ?? 0) } }
    }

    /// Bounds of the corpus's ink, from its sample locations.
    var inkBounds: CGRect {
        strokes.reduce(CGRect.null) { box, stroke in
            stroke.points.reduce(box) { $0.union(CGRect(origin: $1.location, size: .zero)) }
        }
    }

    /// The stroke with the most events: the long shading scribble in the synthetic fixture.
    var longestStroke: InkInputRecording.RecordedStroke? {
        recordedStrokes.max { $0.events.count < $1.events.count }
    }

    /// A page with `count` strokes: copies of the corpus laid over the page at scattered offsets, the
    /// way a dense page of notes piles handwriting up. Deterministic for a given count.
    func page(strokes count: Int) -> [Stroke] {
        guard !strokes.isEmpty else { return [] }
        let box = inkBounds
        let room = CGSize(width: max(pageSize.width - box.width, 1), height: max(pageSize.height - box.height, 1))
        var result: [Stroke] = []
        result.reserveCapacity(count)
        var copy = 0
        while result.count < count {
            // Golden-ratio steps spread the copies evenly without lining them up.
            let fx = (Double(copy) * 0.618_034).truncatingRemainder(dividingBy: 1)
            let fy = (Double(copy) * 0.414_214 + 0.5).truncatingRemainder(dividingBy: 1)
            let d = CGPoint(x: room.width * fx - box.minX, y: room.height * fy - box.minY)
            for stroke in strokes where result.count < count {
                let moved = Stroke(id: UUID(), color: stroke.color, brush: stroke.brush,
                                   points: stroke.points.map { p in
                                       var p = p
                                       p.location.x += d.x
                                       p.location.y += d.y
                                       return p
                                   })
                result.append(moved)
            }
            copy += 1
        }
        return result
    }
}

extension Corpus {
    /// Like `page(strokes:)`, but each copy of the corpus is stretched, sheared and pressed a little
    /// differently, so no two copies have the same point deltas. For measuring compressed sizes: a
    /// compressor would otherwise encode most of a tiled page as references to the first copy.
    func distinctPage(strokes count: Int) -> [Stroke] {
        let perCopy = max(strokes.count, 1)
        return page(strokes: count).enumerated().map { i, stroke in
            let copy = Double(i / perCopy)
            let scale = 1 + 0.12 * sin(copy * 1.7), shear = 0.08 * cos(copy * 2.3)
            let press = 0.9 + 0.1 * sin(copy * 0.9), lean = 0.04 * cos(copy * 1.3)
            var stroke = stroke
            let origin = stroke.points.first?.location ?? .zero
            for j in stroke.points.indices {
                let d = CGPoint(x: stroke.points[j].location.x - origin.x, y: stroke.points[j].location.y - origin.y)
                stroke.points[j].location = CGPoint(x: origin.x + d.x * scale + d.y * shear, y: origin.y + d.y * scale)
                stroke.points[j].force *= press
                stroke.points[j].altitude += lean
                stroke.points[j].timestamp *= scale
            }
            return stroke
        }
    }
}

// MARK: - Results

/// Collects each benchmark's numbers. They're printed, and when `INK_BENCH_RESULTS` names a file (pass
/// `TEST_RUNNER_INK_BENCH_RESULTS` to `xcodebuild`), merged into it as JSON for `scripts/bench-compare.py`.
@MainActor
enum BenchResults {
    struct Metric: Codable {
        var value: Double
        var unit: String
        var budget: Double?
    }

    struct File: Codable {
        var schema = 1
        var environment: [String: String] = [:]
        var metrics: [String: Metric] = [:]
    }

    static func record(_ name: String, _ value: Double, unit: String, budget: Double? = nil) {
        let budgetText = budget.map { String(format: " (budget %.1f %@)", $0, unit) } ?? ""
        print(String(format: "[inkbench] %@ = %.3f %@%@", name, value, unit, budgetText))
        guard let path = ProcessInfo.processInfo.environment["INK_BENCH_RESULTS"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var file = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) ?? File()
        file.environment = environment
        file.metrics[name] = Metric(value: (value * 1000).rounded() / 1000, unit: unit, budget: budget)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(file).write(to: url)
    }

    static var environment: [String: String] {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var cpu = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &cpu, &size, nil, 0)
        return [
            "device": InputRecorder.modelIdentifier,
            "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "host_cpu": String(cString: cpu),
            "configuration": Bench.optimized ? "release" : "debug",
            "corpus": Corpus.shared.recordings.map(\.source.rawValue).joined(separator: "+")
        ]
    }
}
