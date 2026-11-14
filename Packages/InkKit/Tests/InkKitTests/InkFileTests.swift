import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@Suite("Ink file format")
struct InkFileTests {
    // MARK: Round trip

    @Test(arguments: TestBrush.allCases)
    func roundTripsEveryTool(_ kind: TestBrush) throws {
        let strokes = (0 ..< 3).map { scribble(kind, seed: $0, tilt: $0 == 1) }
        let file = InkPageFile(pageID: UUID(), strokes: strokes)
        let decoded = try InkPageFile(data: file.encoded())
        #expect(decoded.pageID == file.pageID)
        #expect(decoded.version == InkPageFile.currentVersion)
        expectClose(decoded.strokes, strokes)
    }

    @Test func reencodingIsByteIdentical() throws {
        let strokes = allKinds.enumerated().map { scribble($1, seed: $0, tilt: true) }
        let once = InkPageFile(pageID: UUID(), strokes: strokes).encoded()
        let decoded = try InkPageFile(data: once)
        #expect(decoded.encoded() == once)
        #expect(try InkPageFile(data: decoded.encoded()) == decoded)
    }

    @Test func keepsDrawingOrderAndSharesBrushes() throws {
        // Two strokes with the same brush and one with another, interleaved.
        let a = scribble(.pen, seed: 1), b = scribble(.highlighter, seed: 2)
        var c = scribble(.pen, seed: 3)
        c.brush = a.brush
        let decoded = try InkPageFile(data: InkPageFile(pageID: UUID(), strokes: [a, b, c]).encoded())
        #expect(decoded.strokes.map(\.id) == [a.id, b.id, c.id])
        #expect(decoded.strokes.map(\.brush.id) == [BrushDescriptor.pen.id, BrushDescriptor.highlighter.id,
                                                    BrushDescriptor.pen.id])
        #expect(decoded.strokes[0].brush == decoded.strokes[2].brush)
    }

    @Test func emptyPageAndEmptyStroke() throws {
        let id = UUID()
        let empty = try InkPageFile(data: InkPageFile(pageID: id).encoded())
        #expect(empty.pageID == id && empty.strokeCount == 0)

        var dot = scribble(.pen, seed: 0)
        dot.points = []
        let decoded = try InkPageFile(data: InkPageFile(pageID: id, strokes: [dot]).encoded())
        #expect(decoded.strokes.first?.points.isEmpty == true)
        #expect(decoded.strokes.first?.id == dot.id)
    }

    @Test func singlePointAndTwoPointStrokes() throws {
        for count in 1 ... 2 {
            var stroke = scribble(.pencil, seed: count)
            stroke.points = Array(stroke.points.prefix(count))
            let decoded = try InkPageFile(data: InkPageFile(pageID: UUID(), strokes: [stroke]).encoded())
            expectClose(decoded.strokes, [stroke])
        }
    }

    @Test func nonFiniteSampleValuesDontTrap() throws {
        var stroke = scribble(.pen, seed: 0)
        stroke.points[1].force = .nan
        stroke.points[2].location.x = .infinity
        stroke.points[3].azimuth = -.infinity
        stroke.color.g = .nan
        stroke.brush.opacity = .nan
        stroke.brush.smoothing = .infinity
        var other = scribble(.pen, seed: 1)
        other.brush = stroke.brush // a second stroke with the same NaN-bearing brush
        let decoded = try InkPageFile(data: InkPageFile(pageID: UUID(), strokes: [stroke, other]).encoded())
        #expect(decoded.strokes[0].brush == decoded.strokes[1].brush)
        #expect(decoded.strokes[0].brush.opacity == 1 && decoded.strokes[0].brush.smoothing == 0.95)
        #expect(decoded.strokes[0].color.g == 0)
        #expect(decoded.strokes[0].points.count == stroke.points.count)
        #expect(decoded.strokes[0].points.allSatisfy { $0.force.isFinite && $0.location.x.isFinite })
    }

    @MainActor
    @Test func pixelEraserSplitsRoundTrip() throws {
        let doc = CanvasDocument()
        let line = makeLine(from: CGPoint(x: 10, y: 100), to: CGPoint(x: 300, y: 100), kind: .pen, width: 4)
        doc.add(line)
        let eraser = makeLine(from: CGPoint(x: 150, y: 40), to: CGPoint(x: 150, y: 160), kind: .pixelEraser,
                              width: 30)
        var coverage = StrokeSplitter.Coverage()
        coverage.add(StrokeRenderer.hulls(for: eraser.points, brush: eraser.brush),
                     within: StrokeRenderer.geometry(for: line).bounds.insetBy(dx: -1, dy: -1))
        let pieces = try #require(StrokeSplitter.pieces(of: line, coverage: coverage))
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.createdAt == line.createdAt })
        doc.add(eraser, splits: [CanvasDocument.Split(index: 0, original: line, pieces: pieces)])
        #expect(doc.strokeCount == 3)

        let reopened = try CanvasDocument(file: InkPageFile(data: doc.inkFile.encoded()), pageSize: doc.pageSize)
        #expect(reopened.id == doc.id)
        expectClose(reopened.strokes, doc.strokes)
        #expect(reopened.strokes.map(\.brush.erases) == [false, false, true])
        #expect(!reopened.canUndo)
    }

    // MARK: Versions and unknown records

    @Test func unknownRecordsArePreservedInPlace() throws {
        let strokes = (0 ..< 3).map { scribble(.pen, seed: $0) }
        let unknown = [
            InkPageFile.UnknownRecord(type: 0x40, payload: [1, 2, 3], position: 0),
            InkPageFile.UnknownRecord(type: 0x41, payload: [], position: 2),
            InkPageFile.UnknownRecord(type: 0xFE, payload: Array(repeating: 9, count: 300), position: 3)
        ]
        let data = InkPageFile(pageID: UUID(), strokes: strokes, unknownRecords: unknown).encoded()
        let decoded = try InkPageFile(data: data)
        #expect(decoded.unknownRecords == unknown)
        #expect(decoded.strokeCount == 3)
        #expect(decoded.encoded() == data)
    }

    @MainActor
    @Test func pageKeepsUnknownRecordsThroughEdits() throws {
        let unknown = [InkPageFile.UnknownRecord(type: 0x50, payload: [7], position: 1)]
        let file = InkPageFile(pageID: UUID(), strokes: [scribble(.pen, seed: 0), scribble(.pen, seed: 1)],
                               unknownRecords: unknown)
        let doc = try CanvasDocument(file: InkPageFile(data: file.encoded()), pageSize: .a4)
        doc.clear()
        let saved = try InkPageFile(data: doc.inkFile.encoded())
        #expect(saved.strokeCount == 0)
        #expect(saved.unknownRecords.map(\.type) == [0x50])
    }

    @Test func readsANewerMinorVersion() throws {
        var data = InkPageFile(pageID: UUID(), strokes: [scribble(.pen, seed: 0)]).encoded()
        data[6] = 7 // minor version, little-endian u16 at offset 6
        #expect(throws: InkFileError.checksumMismatch) { try InkPageFile(data: data) }
        let decoded = try InkPageFile(data: resealed(data))
        #expect(decoded.version == InkPageFile.Version(major: 1, minor: 7))
        #expect(decoded.strokeCount == 1)
        #expect(try InkPageFile(data: decoded.encoded()).version == InkPageFile.currentVersion)
    }

    @Test func refusesAnotherMajorVersion() {
        var data = InkPageFile(pageID: UUID()).encoded()
        data[4] = 2
        #expect(throws: InkFileError.unsupportedVersion(.init(major: 2, minor: 0))) { try InkPageFile(data: data) }
        data[4] = 0
        #expect(throws: InkFileError.unsupportedVersion(.init(major: 0, minor: 0))) { try InkPageFile(data: data) }
    }

    @Test func refusesOtherFiles() {
        #expect(throws: InkFileError.notAnInkFile) { try InkPageFile(data: Data("{\"strokes\":[]}".utf8)) }
        #expect(throws: InkFileError.notAnInkFile) { try InkPageFile(data: Data([0x89, 0x50])) }
        #expect(throws: InkFileError.truncated) { try InkPageFile(data: Data()) }
        #expect(throws: InkFileError.truncated) { try InkPageFile(data: Data("NIN".utf8)) }
    }

    // MARK: Fuzzing

    @Test func everyTruncationThrows() {
        let data = InkPageFile(pageID: UUID(), strokes: (0 ..< 4).map { scribble(.pencil, seed: $0) }).encoded()
        for length in 0 ..< data.count {
            #expect(throws: InkFileError.self) { try InkPageFile(data: data.prefix(length)) }
        }
    }

    @Test func compressesLargePagesAndNotTinyOnes() throws {
        // A brush's JSON alone is over the 256-byte threshold, so the tiny page here is an empty one.
        let small = InkPageFile(pageID: UUID(), strokes: []).encoded()
        #expect(small[24] == InkFileCodec.BodyEncoding.stored.rawValue)
        let large = InkPageFile(pageID: UUID(), strokes: (0 ..< 20).map { scribble(.pen, seed: $0) })
        let data = large.encoded()
        #expect(data[24] == InkFileCodec.BodyEncoding.lzfse.rawValue)
        #expect(data.count < InkFileCodec.encodeBody(large).count)
        #expect(try InkPageFile(data: data) == InkPageFile(data: data))
    }

    @Test func corruptBytesAreCaughtByTheChecksum() {
        let data = InkPageFile(pageID: UUID(), strokes: (0 ..< 4).map { scribble(.pen, seed: $0) }).encoded()
        var rng = SplitMix(seed: 1)
        for _ in 0 ..< 500 {
            var bad = data
            let i = InkFileCodec.headerSize + Int(rng.next() % UInt64(data.count - InkFileCodec.headerSize))
            bad[i] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            #expect(throws: InkFileError.checksumMismatch) { try InkPageFile(data: bad) }
        }
    }

    /// Damages the compressed stream and fixes the checksum up, so the decompressor sees the damage.
    @Test func corruptCompressedBodiesThrow() {
        let data = InkPageFile(pageID: UUID(), strokes: (0 ..< 20).map { scribble(.pencil, seed: $0) }).encoded()
        #expect(data[24] == InkFileCodec.BodyEncoding.lzfse.rawValue)
        var rng = SplitMix(seed: 4)
        for round in 0 ..< 1000 {
            var bad = data
            for _ in 0 ... (round % 4) {
                let i = InkFileCodec.headerSize + Int(rng.next() % UInt64(data.count - InkFileCodec.headerSize))
                bad[i] = UInt8(truncatingIfNeeded: rng.next())
            }
            do {
                _ = try InkPageFile(data: resealed(bad))
            } catch is InkFileError {
            } catch {
                Issue.record("untyped error \(error)")
            }
        }
    }

    /// Header fields (compression, sizes) set to arbitrary values, with the checksum fixed up.
    @Test func corruptHeadersThrow() {
        let data = InkPageFile(pageID: UUID(), strokes: (0 ..< 20).map { scribble(.pen, seed: $0) }).encoded()
        var rng = SplitMix(seed: 5)
        for _ in 0 ..< 1000 {
            var bad = data
            // The body encoding and the two sizes; bytes 25–27 are reserved and ignored.
            let fields = [24] + Array(28 ..< 36)
            let i = fields[Int(rng.next() % UInt64(fields.count))]
            bad[i] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            #expect(throws: InkFileError.self) { try InkPageFile(data: resealed(bad)) }
        }
    }

    /// Corrupts the body and fixes the checksum up, so the parser itself sees the damage. Any outcome but
    /// a crash is acceptable: a typed error, or a file that decodes to something.
    @Test func corruptBodiesNeverCrashTheParser() {
        let strokes = allKinds.enumerated().map { scribble($1, seed: $0, tilt: true) }
        let data = InkPageFile(pageID: UUID(), strokes: strokes).encoded()
        var rng = SplitMix(seed: 2)
        var errors = 0
        for round in 0 ..< 3000 {
            var body = Array(data.dropFirst(InkFileCodec.headerSize))
            for _ in 0 ... (round % 6) {
                let i = Int(rng.next() % UInt64(body.count))
                switch rng.next() % 4 {
                case 0: body[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: body[i] = 0xFF
                case 2: body.remove(at: i)
                default: body.insert(UInt8(truncatingIfNeeded: rng.next()), at: i)
                }
                if body.isEmpty {
                    break
                }
            }
            do {
                _ = try InkPageFile(data: withHeader(of: data, body: body))
            } catch is InkFileError {
                errors += 1
            } catch {
                Issue.record("untyped error \(error)")
            }
        }
        #expect(errors > 0)
    }

    @Test func randomBytesNeverCrash() {
        var rng = SplitMix(seed: 3)
        let header = InkPageFile(pageID: UUID()).encoded()
        for round in 0 ..< 2000 {
            let body = (0 ..< Int(rng.next() % 200)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let data = round.isMultiple(of: 2) ? withHeader(of: header, body: body) : Data(body)
            do {
                _ = try InkPageFile(data: data)
            } catch is InkFileError {
            } catch {
                Issue.record("untyped error \(error)")
            }
        }
    }

    @Test func hugeCountsAreRejectedWithoutAllocating() {
        // A brush table claiming 2^62 brushes in a 10-byte payload.
        var body: [UInt8] = [1, 9]
        body += [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40]
        let data = withHeader(of: InkPageFile(pageID: UUID()).encoded(), body: body)
        #expect(throws: InkFileError.self) { try InkPageFile(data: data) }
    }

    @Test func crcMatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum([]) == 0)
        // Split updates agree with one pass, whatever the alignment.
        let bytes = (0 ..< 1031).map { UInt8(truncatingIfNeeded: $0 &* 37) }
        var crc = CRC32()
        crc.update(Array(bytes[..<5]))
        crc.update(Array(bytes[5...]))
        #expect(crc.value == CRC32.checksum(bytes))
    }

    @Test func brushesThatAreNotJSONObjectsThrow() {
        let valid = InkPageFile(pageID: UUID()).encoded()
        // A brush table (type 1, 4 bytes) holding one brush (2 bytes of JSON) that's an array.
        let data = withHeader(of: valid, body: [1, 4, 1, 2] + Array("[]".utf8))
        #expect(throws: InkFileError.self) { try InkPageFile(data: data) }
    }

    // MARK: Size

    @Test func pointsTakeAFewBytesEach() {
        let strokes = (0 ..< 50).map { scribble(.pen, seed: $0, count: 200) }
        let size = InkPageFile(pageID: UUID(), strokes: strokes).encoded().count
        let points = strokes.reduce(0) { $0 + $1.points.count }
        // Smooth, regular 240 Hz input: well under the 16 bytes per point of four f32s.
        let perPoint = Double(size) / Double(points)
        #expect(perPoint < 4, "\(perPoint) bytes per point")
    }

    // MARK: Helpers

    /// `file`'s magic, version and page id over an uncompressed `body`, with a correct checksum.
    private func withHeader(of file: Data, body: [UInt8]) -> Data {
        var data = Data(file.prefix(24))
        data.append(contentsOf: [InkFileCodec.BodyEncoding.stored.rawValue, 0, 0, 0])
        let length = UInt32(body.count)
        for _ in 0 ..< 2 {
            withUnsafeBytes(of: length.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: body)
        return resealed(data)
    }

    /// `data` with its checksum recomputed.
    private func resealed(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        guard bytes.count >= InkFileCodec.headerSize else { return data }
        let at = InkFileCodec.checksumOffset
        let crc = CRC32.checksum(Array(bytes[..<at]) + Array(bytes[InkFileCodec.headerSize...]))
        withUnsafeBytes(of: crc.littleEndian) { bytes.replaceSubrange(at ..< at + 4, with: $0) }
        return Data(bytes)
    }

    private func expectClose(_ decoded: [Stroke], _ original: [Stroke],
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(decoded.count == original.count, sourceLocation: sourceLocation)
        for (d, o) in zip(decoded, original) {
            #expect(d.id == o.id && d.brush == o.brush, sourceLocation: sourceLocation)
            #expect(d.createdAt == o.createdAt, sourceLocation: sourceLocation)
            #expect(abs(d.color.r - o.color.r) < 1e-6 && abs(d.color.a - o.color.a) < 1e-6,
                    sourceLocation: sourceLocation)
            #expect(d.points.count == o.points.count, sourceLocation: sourceLocation)
            let close = zip(d.points, o.points).allSatisfy { p, q in
                abs(p.location.x - q.location.x) <= 0.5 / 64 + 1e-9
                    && abs(p.location.y - q.location.y) <= 0.5 / 64 + 1e-9
                    && abs(p.force - q.force) <= 0.5 / 1024 + 1e-9
                    && abs(p.altitude - q.altitude) <= 0.5 / 1024 + 1e-9
                    && abs(p.azimuth - q.azimuth) <= 0.5 / 1024 + 1e-9
                    && abs(p.timestamp - q.timestamp) <= 0.5 / 4096 + 1e-9
            }
            #expect(close, "points differ beyond quantisation", sourceLocation: sourceLocation)
        }
    }
}

private let allKinds = TestBrush.allCases

/// A wavy handwriting-like stroke sampled at 240 Hz, with pressure and (optionally) tilt varying.
private func scribble(_ kind: TestBrush, seed: Int, tilt: Bool = false, count: Int = 60) -> Stroke {
    var rng = SplitMix(seed: UInt64(seed) + 100)
    let origin = CGPoint(x: 40 + Double(rng.next() % 400), y: 40 + Double(rng.next() % 600))
    let start = 1000 + Double(seed) * 3.7
    let points = (0 ..< count).map { i -> StrokePoint in
        let t = Double(i) / 240
        let jitter = Double(rng.next() % 1000) / 1000 - 0.5
        return StrokePoint(location: CGPoint(x: origin.x + t * 300 + jitter * 0.1,
                                             y: origin.y + sin(t * 40) * 12 + jitter * 0.1),
                           force: 0.4 + 0.3 * sin(t * 9) + jitter * 0.01,
                           altitude: tilt ? 0.6 + 0.4 * cos(t * 5) : .pi / 2,
                           azimuth: tilt ? -0.8 + t : 0,
                           timestamp: start + t)
    }
    let brush = kind.brush(width: kind == .highlighter ? 18 : 3 + CGFloat(seed % 4), minWidthRatio: 0.3,
                           pressureExponent: 0.7, opacity: kind == .highlighter ? 0.35 : nil, tilt: tilt)
    return Stroke(id: UUID(), color: RGBA(r: 0.1 * CGFloat(seed % 10), g: 0.3, b: 0.77, a: 1),
                  brush: brush, points: points,
                  createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(seed) * 1.25))
}

private func makeLine(from a: CGPoint, to b: CGPoint, kind: TestBrush, width: CGFloat) -> Stroke {
    let n = 40
    let points = (0 ... n).map { i -> StrokePoint in
        let t = CGFloat(i) / CGFloat(n)
        return StrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), force: 1,
                           altitude: .pi / 2, azimuth: 0, timestamp: Double(i) / 240)
    }
    let brush = kind.brush(width: width, minWidthRatio: 1, pressureExponent: 1)
    return Stroke(id: UUID(), color: RGBA.swatches[0], brush: brush, points: points)
}

/// Small deterministic PRNG, so fuzz failures reproduce.
struct SplitMix {
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
}
