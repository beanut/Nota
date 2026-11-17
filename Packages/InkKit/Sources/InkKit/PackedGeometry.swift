import CoreGraphics
import Foundation

/// A stroke's geometry packed small for keeping (NOT-108), and unpacked again into `CGPath`s to draw.
///
/// A dense stroke's outline is ~2,000 points across ~120 closed polygons, and as `CGPath`s that's ~60 KB
/// (a 5k-stroke page held ~300 MB of heap). Two thirds of the points are nib stamps, each a regular polygon
/// of 8–64 sides that `StrokeRenderer.polygon(for:sides:)` makes from five numbers, so a stamp keeps just
/// those; the strips between them keep their points as varint deltas on a 1/8192 pt grid (about as fine
/// as `Float` at page scale, a thousandth of a pixel at the deepest zoom). A packed geometry is ~4 KB,
/// about 15× smaller, and unpacks in a tenth of the time building it from the stroke's samples takes.
///
/// A stamp is only kept as numbers when its polygon, made again from them, lands within 1/1000 pt of every
/// point it had; anything else (a dot's convex hull, a path with curves) keeps its points, or its paths
/// as they are, so packing never changes what's drawn by more than rounding.
struct PackedGeometry: @unchecked Sendable { // immutable; `raw`'s paths are never mutated
    let bounds: CGRect
    private let runs: [Run]
    private let bytes: [UInt8]
    /// The runs as built, for a path packing can't describe.
    private let raw: [StrokeRun]?

    private struct Run {
        let alpha: CGFloat
        let shapes: Int
        let stamps: [RasterStamp]
    }

    /// Grid steps per point for packed coordinates and radii, and per radian for a stamp's angle.
    private static let grid: CGFloat = 8192
    private static let angleGrid: CGFloat = 1_048_576
    /// One grid step, in points (a power of two, so multiplying by it is exactly dividing by `grid`).
    private static let step: CGFloat = 1 / grid
    /// How far a stamp's polygon made again may land from its own points and still be kept as numbers.
    private static let stampTolerance: CGFloat = 0.001
    private static let stampSides: Set<Int> = [8, 16, 32, 64]

    /// What keeping it costs, in bytes (an estimate of the heap it holds, for the cache's budget).
    let byteCount: Int
    /// What keeping it unpacked costs: about 30 bytes of `CGPath` a point (a dense page's 10M points held
    /// ~295 MB).
    let unpackedByteCount: Int

    init(_ geometry: StrokeGeometry) {
        bounds = geometry.bounds
        var writer = Writer()
        var runs: [Run] = []
        runs.reserveCapacity(geometry.runs.count)
        for run in geometry.runs {
            guard let shapes = writer.append(run.path) else {
                self.runs = []
                bytes = []
                raw = geometry.runs
                byteCount = Self.rawByteCount(geometry.runs)
                unpackedByteCount = byteCount
                return
            }
            runs.append(Run(alpha: run.alpha, shapes: shapes, stamps: run.stamps))
        }
        self.runs = runs
        bytes = writer.packed()
        raw = nil
        unpackedByteCount = 128 + runs.count * 64 + writer.pointCount * 30
        byteCount = 96 + bytes.count + runs.count * MemoryLayout<Run>.stride
            + runs.reduce(0) { $0 + $1.stamps.count * MemoryLayout<RasterStamp>.stride }
    }

    /// Whether the paths were packed (rather than kept as they were built).
    var isPacked: Bool {
        raw == nil
    }

    /// The geometry again, as `StrokeRenderer` draws it.
    func unpacked() -> StrokeGeometry {
        if let raw {
            return StrokeGeometry(runs: raw, bounds: bounds)
        }
        let result = bytes.withUnsafeBufferPointer { buffer in
            var reader = Reader(bytes: buffer)
            return runs.map { run in
                let path = CGMutablePath()
                for _ in 0 ..< run.shapes {
                    reader.readShape(into: path)
                }
                return StrokeRun(path: path, alpha: run.alpha, stamps: run.stamps)
            }
        }
        return StrokeGeometry(runs: result, bounds: bounds)
    }

    /// Roughly what `CGPath`s holding `runs` cost (see `unpackedByteCount`).
    private static func rawByteCount(_ runs: [StrokeRun]) -> Int {
        var points = 0
        for run in runs {
            run.path.applyWithBlock { _ in points += 1 }
        }
        return 128 + points * 30
    }

    // MARK: Writing

    private struct Writer {
        var out: [UInt8] = []
        /// The last point written, on the grid: points are written as steps from it.
        var cursor = (x: 0, y: 0)
        var points: [CGPoint] = []
        /// Where each closed polygon of the path being appended ends in `points`.
        var ends: [Int] = []
        /// Points in the paths written, stamps' included.
        var pointCount = 0

        init() {
            out.reserveCapacity(4096)
            points.reserveCapacity(2048)
        }

        /// Appends a run's path; nil if it isn't only closed polygons (move, lines, close).
        mutating func append(_ path: CGPath) -> Int? {
            var points = points, ends = ends
            points.removeAll(keepingCapacity: true)
            ends.removeAll(keepingCapacity: true)
            var valid = true
            var open = false
            path.applyWithBlock { element in
                let e = element.pointee
                switch e.type {
                case .moveToPoint:
                    valid = valid && !open
                    points.append(e.points[0])
                    open = true
                case .addLineToPoint:
                    valid = valid && open
                    points.append(e.points[0])
                case .closeSubpath:
                    valid = valid && open
                    ends.append(points.count)
                    open = false
                default:
                    valid = false
                }
            }
            defer {
                self.points = points
                self.ends = ends
            }
            guard valid, !open else { return nil }
            points.withUnsafeBufferPointer { all in
                var start = 0
                for end in ends {
                    writeShape(UnsafeBufferPointer(rebasing: all[start ..< end]))
                    start = end
                }
            }
            return ends.count
        }

        private mutating func writeShape(_ points: UnsafeBufferPointer<CGPoint>) {
            pointCount += points.count
            if let stamp = PackedGeometry.stamp(fitting: points) {
                writeUnsigned(UInt64(points.count) << 1 | 1)
                writePoint(stamp.center)
                writeUnsigned(UInt64(stamp.major))
                writeUnsigned(UInt64(stamp.minor))
                writeSigned(stamp.angle)
                return
            }
            writeUnsigned(UInt64(points.count) << 1)
            for p in points {
                writePoint(PackedGeometry.onGrid(p))
            }
        }

        private mutating func writePoint(_ p: (x: Int, y: Int)) {
            writeSigned(p.x - cursor.x)
            writeSigned(p.y - cursor.y)
            cursor = p
        }

        private mutating func writeSigned(_ v: Int) {
            writeUnsigned(UInt64(bitPattern: Int64((v << 1) ^ (v >> 63))))
        }

        private mutating func writeUnsigned(_ v: UInt64) {
            var v = v
            while v >= 0x80 {
                out.append(UInt8(truncatingIfNeeded: v) | 0x80)
                v >>= 7
            }
            out.append(UInt8(v))
        }

        /// The bytes, in an array exactly their size.
        func packed() -> [UInt8] {
            [UInt8](unsafeUninitializedCapacity: out.count) { buffer, count in
                _ = out.withUnsafeBufferPointer { memcpy(buffer.baseAddress!, $0.baseAddress!, out.count) }
                count = out.count
            }
        }
    }

    private static func onGrid(_ p: CGPoint) -> (x: Int, y: Int) {
        (Int((p.x * grid).rounded()), Int((p.y * grid).rounded()))
    }

    /// A nib stamp on the grid: centre and radii in grid steps, angle in angle-grid steps.
    private struct GridStamp {
        let center: (x: Int, y: Int)
        let major: Int
        let minor: Int
        let angle: Int

        var tip: Tip {
            Tip(center: CGPoint(x: CGFloat(center.x) / grid, y: CGFloat(center.y) / grid),
                major: CGFloat(major) / grid, minor: CGFloat(minor) / grid, angle: CGFloat(angle) / angleGrid,
                alpha: 1)
        }
    }

    /// The stamp whose polygon `points` are, if they're one `StrokeRenderer.polygon(for:sides:)` made.
    private static func stamp(fitting points: UnsafeBufferPointer<CGPoint>) -> GridStamp? {
        let n = points.count
        guard n == 16 || n == 32 || n == 8 || n == 64 else { return nil }
        var cx: CGFloat = 0, cy: CGFloat = 0
        for p in points {
            cx += p.x
            cy += p.y
        }
        cx /= CGFloat(n)
        cy /= CGFloat(n)
        // Point 0 lies along the major axis, point n/4 along the minor one.
        let ax = points[0].x - cx, ay = points[0].y - cy
        let major = (ax * ax + ay * ay).squareRoot()
        guard major > 1e-6 else { return nil }
        let angle = atan2(ay, ax)
        let c = cos(angle), s = sin(angle)
        let minor = (points[n / 4].x - cx) * -s + (points[n / 4].y - cy) * c
        guard minor > 1e-6 else { return nil }
        let stamp = GridStamp(center: onGrid(CGPoint(x: cx, y: cy)), major: Int((major * grid).rounded()),
                              minor: Int((minor * grid).rounded()), angle: Int((angle * angleGrid).rounded()))
        var fits = true
        stampPoints(stamp.tip, sides: n) { i, p in
            if abs(p.x - points[i].x) > stampTolerance || abs(p.y - points[i].y) > stampTolerance {
                fits = false
            }
        }
        return fits ? stamp : nil
    }

    /// The unit circles `StrokeRenderer.polygon(for:sides:)` scales, made the same way, by sides.
    private static let circles: [Int: [(x: CGFloat, y: CGFloat)]] = {
        var table: [Int: [(x: CGFloat, y: CGFloat)]] = [:]
        for n in stampSides {
            table[n] = (0 ..< n).map { i in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                return (cos(t), sin(t))
            }
        }
        return table
    }()

    private static let circle8 = circles[8]!, circle16 = circles[16]!, circle32 = circles[32]!, circle64 = circles[64]!

    /// The points of `tip`'s polygon of `sides` (8, 16, 32 or 64), as `StrokeRenderer.polygon(for:sides:)`
    /// makes them, handed to `body` in order without an array.
    @inline(__always)
    private static func stampPoints(_ tip: Tip, sides: Int, _ body: (Int, CGPoint) -> Void) {
        let circle = sides == 16 ? circle16 : sides == 32 ? circle32 : sides == 64 ? circle64 : circle8
        let c = cos(tip.angle), s = sin(tip.angle)
        for i in 0 ..< circle.count {
            let x = circle[i].x * tip.major, y = circle[i].y * tip.minor
            body(i, CGPoint(x: tip.center.x + x * c - y * s, y: tip.center.y + x * s + y * c))
        }
    }

    // MARK: Reading

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var at = 0
        var cursor = (x: 0, y: 0)
        var points: [CGPoint] = []

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            points.reserveCapacity(256)
        }

        mutating func readShape(into path: CGMutablePath) {
            let header = readUnsigned()
            let count = Int(header >> 1)
            if header & 1 == 1 {
                let center = readPoint()
                let major = Int(readUnsigned()), minor = Int(readUnsigned()), angle = readSigned()
                let stamp = GridStamp(center: center, major: major, minor: minor, angle: angle)
                points.removeAll(keepingCapacity: true)
                PackedGeometry.stampPoints(stamp.tip, sides: count) { _, p in points.append(p) }
                path.addLines(between: points)
            } else {
                points.removeAll(keepingCapacity: true)
                for _ in 0 ..< count {
                    let p = readPoint()
                    points.append(CGPoint(x: CGFloat(p.x) * step, y: CGFloat(p.y) * step))
                }
                path.addLines(between: points)
            }
            path.closeSubpath()
        }

        private mutating func readPoint() -> (x: Int, y: Int) {
            cursor = (cursor.x + readSigned(), cursor.y + readSigned())
            return cursor
        }

        private mutating func readSigned() -> Int {
            let u = readUnsigned()
            return Int(Int64(bitPattern: u >> 1) ^ -Int64(bitPattern: u & 1))
        }

        private mutating func readUnsigned() -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                let byte = bytes[at]
                at += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 {
                    return result
                }
                shift += 7
            }
        }
    }
}

extension StrokeRenderer {
    /// A stroke's geometry as a page keeps it and its tiles are filled from: built, packed and unpacked. Fills
    /// always draw this, whether they built the stroke or found it kept, so a tile's pixels don't depend on
    /// which job built what (the tests' tiles drawn from scratch use it too).
    static func keptGeometry(for stroke: Stroke) -> StrokeGeometry {
        PackedGeometry(geometry(for: stroke)).unpacked()
    }
}
