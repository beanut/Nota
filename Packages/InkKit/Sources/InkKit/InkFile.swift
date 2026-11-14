import Compression
import CoreGraphics
import Foundation

/// One page's ink in the `.ink` file format (v1): the page's strokes in order, plus any records written by
/// a newer version of the format, kept so that saving the page again doesn't drop them.
///
/// Decode it off the main actor, then build the page on it with `CanvasDocument(file:pageSize:)`; take
/// one back from a page with `CanvasDocument.inkFile` and encode it with `encoded()`. The paper size isn't
/// part of the file: it lives in the note's manifest. The byte layout is in InkKit's README › Ink file
/// format.
public struct InkPageFile: Equatable, Sendable {
    /// Format version: readers refuse another major version and read any minor version of their own.
    public struct Version: Hashable, Comparable, Sendable, CustomStringConvertible {
        public var major: UInt16
        public var minor: UInt16

        public init(major: UInt16, minor: UInt16) {
            self.major = major
            self.minor = minor
        }

        public static func < (a: Version, b: Version) -> Bool {
            (a.major, a.minor) < (b.major, b.minor)
        }

        public var description: String {
            "\(major).\(minor)"
        }
    }

    /// A record of a type this version doesn't know, written by a newer minor version. It's written back
    /// unchanged, after the same number of strokes as before (or at the end if strokes were removed).
    struct UnknownRecord: Equatable, Sendable {
        var type: UInt8
        var payload: [UInt8]
        /// Number of strokes before the record in the file.
        var position: Int
    }

    /// The version this build writes.
    public static let currentVersion = Version(major: 1, minor: 0)
    public static let fileExtension = "ink"

    /// The id of the page the ink belongs to (`CanvasDocument.id`).
    public var pageID: UUID
    /// The version the file was written with (`currentVersion` for a file built in memory).
    public private(set) var version: Version
    /// The page's strokes in drawing order, including pixel-eraser strokes.
    var strokes: [Stroke]
    var unknownRecords: [UnknownRecord]

    public var strokeCount: Int {
        strokes.count
    }

    init(pageID: UUID, strokes: [Stroke], unknownRecords: [UnknownRecord] = [], version: Version = currentVersion) {
        self.pageID = pageID
        self.strokes = strokes
        self.unknownRecords = unknownRecords
        self.version = version
    }

    /// An empty page.
    public init(pageID: UUID) {
        self.init(pageID: pageID, strokes: [])
    }

    /// Reads a `.ink` file. Throws an `InkFileError` for anything that isn't a well-formed file this
    /// version can read; it never traps on bad input.
    public init(data: Data) throws {
        self = try InkFileCodec.decode(data)
    }

    /// The page in the `.ink` format, at `currentVersion`.
    public func encoded() -> Data {
        InkFileCodec.encode(self)
    }
}

/// Why a `.ink` file couldn't be read.
public enum InkFileError: Error, Equatable, Sendable {
    /// The data doesn't start with the `.ink` magic number.
    case notAnInkFile
    /// Written with another major version: by a newer app, or in a format this one never read.
    case unsupportedVersion(InkPageFile.Version)
    /// The data ends in the middle of the header or the body.
    case truncated
    /// The contents don't match their checksum.
    case checksumMismatch
    /// Structurally invalid: a bad varint or length, an out-of-range index, a non-finite number and so on.
    case corrupt(String)
}

// MARK: - Codec

/// The byte-level encoding; see InkKit's README › Ink file format for the layout. Everything is
/// little-endian.
enum InkFileCodec {
    static let magic: [UInt8] = Array("NINK".utf8)
    static let headerSize = 40
    /// Offset of the CRC, which covers every byte before it and the stored body after it.
    static let checksumOffset = 36

    enum RecordType: UInt8 {
        case brushes = 1
        case stroke = 2
    }

    enum BodyEncoding: UInt8 {
        case stored = 0
        case lzfse = 1
    }

    /// Quantisation steps, as their reciprocals. All powers of two, so a decoded value quantises back to
    /// the same integer and re-saving a page never drifts.
    enum Scale {
        static let location: Double = 64 // 1/64 pt
        static let force: Double = 1024
        static let angle: Double = 1024 // 1/1024 rad
        static let time: Double = 4096 // 1/4096 s
    }

    /// The largest body a reader will accept, so a corrupt length can't ask for an absurd allocation.
    static let maxBodySize = 1 << 29
    /// The writer never compresses more than this, so a reader can bound the body by the stored size.
    static let maxCompressionRatio = 256

    /// `v`, or 0 if it's NaN or infinite.
    static func finite(_ v: CGFloat) -> CGFloat {
        v.isFinite ? v : 0
    }

    // MARK: Encoding

    static func encode(_ file: InkPageFile) -> Data {
        let body = encodeBody(file)
        var encoding = BodyEncoding.stored
        var stored = body
        if body.count > 256, body.count <= maxBodySize, let packed = lzfse(body),
           packed.count * maxCompressionRatio >= body.count {
            encoding = .lzfse
            stored = packed
        }

        var out = ByteWriter()
        out.reserve(headerSize + stored.count)
        out.append(magic)
        out.u16(InkPageFile.currentVersion.major)
        out.u16(InkPageFile.currentVersion.minor)
        out.uuid(file.pageID)
        out.u8(encoding.rawValue)
        out.append([0, 0, 0])
        out.u32(UInt32(stored.count))
        out.u32(UInt32(body.count))
        var crc = CRC32()
        crc.update(out.bytes)
        crc.update(stored)
        out.u32(crc.value)
        out.append(stored)
        return Data(out.bytes)
    }

    static func encodeBody(_ file: InkPageFile) -> [UInt8] {
        // Each distinct brush once, clamped so it hashes consistently (NaN never equals itself) and
        // re-reads as the same descriptor (decoding clamps).
        var brushes: [BrushDescriptor] = []
        var brushIndex: [BrushDescriptor: Int] = [:]
        var strokeBrush: [Int] = []
        strokeBrush.reserveCapacity(file.strokes.count)
        var last: (raw: BrushDescriptor, index: Int)?
        for stroke in file.strokes {
            if let last, last.raw == stroke.brush { // strokes in a row usually share their brush
                strokeBrush.append(last.index)
                continue
            }
            let brush = stroke.brush.clamped()
            let index = brushIndex[brush] ?? brushes.count
            if index == brushes.count {
                brushIndex[brush] = index
                brushes.append(brush)
            }
            strokeBrush.append(index)
            last = (stroke.brush, index)
        }

        // Stroke records are independent, so they're encoded in parallel, a chunk of strokes at a time.
        let strokes = file.strokes
        let chunks = (strokes.count + strokesPerChunk - 1) / strokesPerChunk
        var parts = [(bytes: [UInt8], ends: [Int])](repeating: ([], []), count: chunks)
        parts.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                var part = ByteWriter(), scratch = ByteWriter()
                var ends: [Int] = []
                let range = c * strokesPerChunk ..< min(strokes.count, (c + 1) * strokesPerChunk)
                part.reserve(strokes[range].reduce(0) { $0 + 64 + $1.points.count * 7 })
                for i in range {
                    scratch.removeAll()
                    write(strokes[i], brush: strokeBrush[i], into: &scratch)
                    part.record(type: RecordType.stroke.rawValue, scratch.bytes)
                    ends.append(part.bytes.count)
                }
                out[c] = (part.bytes, ends)
            }
        }

        var body = ByteWriter()
        body.reserve(parts.reduce(64 + 34 * brushes.count) { $0 + $1.bytes.count })
        var scratch = ByteWriter()
        writeBrushes(brushes, into: &scratch)
        body.record(type: RecordType.brushes.rawValue, scratch.bytes)
        let unknown = file.unknownRecords.sorted { $0.position < $1.position }
        if unknown.isEmpty {
            for part in parts {
                body.append(part.bytes)
            }
            return body.bytes
        }
        var nextUnknown = 0
        func flushUnknown(upTo position: Int) {
            while nextUnknown < unknown.count, unknown[nextUnknown].position <= position {
                body.record(type: unknown[nextUnknown].type, unknown[nextUnknown].payload)
                nextUnknown += 1
            }
        }
        for (c, part) in parts.enumerated() {
            var start = 0
            for (k, end) in part.ends.enumerated() {
                flushUnknown(upTo: c * strokesPerChunk + k)
                body.append(part.bytes[start ..< end])
                start = end
            }
        }
        flushUnknown(upTo: .max)
        return body.bytes
    }

    /// Strokes encoded or decoded per parallel work item.
    static let strokesPerChunk = 64

    /// Each brush is its descriptor's JSON (sorted keys, so the same brush always writes the same bytes),
    /// length-prefixed. JSON keeps the table readable by any later version: fields a newer descriptor adds
    /// are ignored by older readers, and fields it lacks take their defaults.
    private static func writeBrushes(_ brushes: [BrushDescriptor], into w: inout ByteWriter) {
        w.varint(UInt64(brushes.count))
        for brush in brushes {
            let json = (try? brush.jsonData()) ?? Data("{}".utf8)
            w.varint(UInt64(json.count))
            w.append(json)
        }
    }

    private static func write(_ stroke: Stroke, brush: Int, into w: inout ByteWriter) {
        w.uuid(stroke.id)
        w.varint(UInt64(brush))
        for c in [stroke.color.r, stroke.color.g, stroke.color.b, stroke.color.a] {
            // Clamped so an out-of-range component can't round to an infinite f32.
            w.f32(Float(min(max(finite(c), -1e30), 1e30)))
        }
        let created = stroke.createdAt.timeIntervalSinceReferenceDate
        w.f64(created.isFinite ? created : 0)
        let points = stroke.points
        let base = points.first?.timestamp ?? 0
        w.f64(base.isFinite ? base : 0)
        w.varint(UInt64(points.count))
        guard !points.isEmpty else { return }
        w.column(points, order: 2) { quantise($0.location.x, Scale.location) }
        w.column(points, order: 2) { quantise($0.location.y, Scale.location) }
        w.column(points, order: 1) { quantise($0.force, Scale.force) }
        w.column(points, order: 1) { quantise($0.altitude, Scale.angle) }
        w.column(points, order: 1) { quantise($0.azimuth, Scale.angle) }
        w.column(points, order: 2) { quantise($0.timestamp - base, Scale.time) }
    }

    /// Bounded so that any input, finite or not, gives a value whose deltas can't overflow.
    @inline(__always)
    static func quantise(_ value: some BinaryFloatingPoint, _ scale: Double) -> Int64 {
        let limit = Double(1 << 52)
        let q = (Double(value) * scale).rounded()
        guard q.isFinite else { return 0 }
        return Int64(min(max(q, -limit), limit))
    }

    private static func lzfse(_ bytes: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: bytes.count)
        let size = bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil,
                                          COMPRESSION_LZFSE)
            }
        }
        guard size > 0 else { return nil }
        out.removeSubrange(size...)
        return out
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> InkPageFile {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var header = ByteReader(raw)
            guard raw.count >= magic.count else {
                throw magic.starts(with: raw) ? InkFileError.truncated : InkFileError.notAnInkFile
            }
            guard try header.bytes(magic.count).elementsEqual(magic) else { throw InkFileError.notAnInkFile }
            // The major version comes first: a different major may lay out everything after it differently.
            let version = try InkPageFile.Version(major: header.u16(), minor: header.u16())
            guard version.major == InkPageFile.currentVersion.major else {
                throw InkFileError.unsupportedVersion(version)
            }
            let pageID = try header.uuid()
            let encoding = try header.u8()
            _ = try header.bytes(3)
            let storedSize = try Int(header.u32())
            let bodySize = try Int(header.u32())
            let checksum = try header.u32()
            guard header.remaining >= storedSize else { throw InkFileError.truncated }
            let stored = UnsafeRawBufferPointer(rebasing: raw[headerSize ..< headerSize + storedSize])
            var crc = CRC32()
            crc.update(UnsafeRawBufferPointer(rebasing: raw[0 ..< checksumOffset]))
            crc.update(stored)
            guard crc.value == checksum else { throw InkFileError.checksumMismatch }

            switch BodyEncoding(rawValue: encoding) {
            case .stored:
                guard bodySize == storedSize else { throw InkFileError.corrupt("body size") }
                return try decodeBody(stored, pageID: pageID, version: version)
            case .lzfse:
                guard bodySize <= maxBodySize, bodySize <= storedSize * maxCompressionRatio else {
                    throw InkFileError.corrupt("body size")
                }
                let body = try unlzfse(stored, size: bodySize)
                return try body.withUnsafeBytes { try decodeBody($0, pageID: pageID, version: version) }
            case nil:
                throw InkFileError.corrupt("unknown body encoding")
            }
        }
    }

    private static func unlzfse(_ stored: UnsafeRawBufferPointer, size: Int) throws -> [UInt8] {
        guard size > 0, let src = stored.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw InkFileError.corrupt("empty compressed body")
        }
        // One spare byte, so a stream that decodes to more than `size` shows up as a size mismatch.
        var body = [UInt8](repeating: 0, count: size + 1)
        let decoded = body.withUnsafeMutableBufferPointer { dst in
            compression_decode_buffer(dst.baseAddress!, dst.count, src, stored.count, nil, COMPRESSION_LZFSE)
        }
        guard decoded == size else { throw InkFileError.corrupt("compressed body") }
        body.removeLast()
        return body
    }

    static func decodeBody(_ body: UnsafeRawBufferPointer, pageID: UUID,
                           version: InkPageFile.Version) throws -> InkPageFile {
        var file = InkPageFile(pageID: pageID, strokes: [], version: version)
        var brushes: [BrushDescriptor]?
        var strokeRecords: [UnsafeRawBufferPointer] = []
        var reader = ByteReader(body)
        while reader.remaining > 0 {
            let type = try reader.u8()
            let payload = try reader.slice(reader.length())
            switch RecordType(rawValue: type) {
            case .brushes:
                guard brushes == nil else { throw InkFileError.corrupt("second brush table") }
                var r = ByteReader(payload)
                brushes = try readBrushes(&r)
            case .stroke:
                guard brushes != nil else { throw InkFileError.corrupt("stroke before brush table") }
                strokeRecords.append(payload)
            case nil:
                file.unknownRecords.append(.init(type: type, payload: Array(payload), position: strokeRecords.count))
            }
        }
        file.strokes = try readStrokes(strokeRecords, brushes: brushes ?? [])
        return file
    }

    /// Decodes stroke records in parallel, a chunk at a time. Throws the error of the first bad record.
    private static func readStrokes(_ records: [UnsafeRawBufferPointer], brushes: [BrushDescriptor]) throws -> [Stroke] {
        let chunks = (records.count + strokesPerChunk - 1) / strokesPerChunk
        var strokes = [Stroke?](repeating: nil, count: records.count)
        var errors = [InkFileError?](repeating: nil, count: chunks)
        strokes.withUnsafeMutableBufferPointer { out in
            errors.withUnsafeMutableBufferPointer { failures in
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    var columns = ColumnScratch()
                    for i in c * strokesPerChunk ..< min(records.count, (c + 1) * strokesPerChunk) {
                        var r = ByteReader(records[i])
                        do {
                            // A newer minor version may append fields to a stroke; this version skips them.
                            out[i] = try readStroke(&r, brushes: brushes, columns: &columns)
                        } catch {
                            failures[c] = error as? InkFileError ?? .corrupt("\(error)")
                            return
                        }
                    }
                }
            }
        }
        if let failure = errors.lazy.compactMap({ $0 }).first {
            throw failure
        }
        return strokes.compactMap { $0 }
    }

    private static func readBrushes(_ r: inout ByteReader) throws -> [BrushDescriptor] {
        // A length and at least `{}`.
        let count = try r.count(minimumBytesEach: 3)
        var brushes: [BrushDescriptor] = []
        brushes.reserveCapacity(count)
        let decoder = JSONDecoder()
        for _ in 0 ..< count {
            let json = try r.bytes(r.length())
            // Lenient and clamped: any JSON object is a drawable brush. Anything else is damage.
            guard let brush = try? decoder.decode(BrushDescriptor.self, from: Data(json)) else {
                throw InkFileError.corrupt("brush")
            }
            brushes.append(brush)
        }
        return brushes
    }

    /// Reused buffers for one stroke's decoded columns.
    struct ColumnScratch {
        var values: [[Int64]] = Array(repeating: [], count: 6)
    }

    private static func readStroke(_ r: inout ByteReader, brushes: [BrushDescriptor],
                                   columns: inout ColumnScratch) throws -> Stroke {
        let id = try r.uuid()
        let brushIndex = try r.varint()
        guard brushIndex < brushes.count else { throw InkFileError.corrupt("brush index out of range") }
        let brush = brushes[Int(brushIndex)]
        let color = try RGBA(r: r.finite(r.f32()), g: r.finite(r.f32()), b: r.finite(r.f32()), a: r.finite(r.f32()))
        let createdAt = try Date(timeIntervalSinceReferenceDate: r.finite(r.f64()))
        let base = try r.finite(r.f64())
        // Each point takes at least one byte in each of the six columns.
        let count = try r.count(minimumBytesEach: 6)
        for c in 0 ..< 6 {
            // x, y and time are second-order; force, altitude and azimuth first-order.
            try r.column(count, order: c < 2 || c == 5 ? 2 : 1, into: &columns.values[c])
        }
        let points = columns.values.withUnsafeBufferPointer { v in
            let (x, y, f, alt, az, t) = (v[0], v[1], v[2], v[3], v[4], v[5])
            return [StrokePoint](unsafeUninitializedCapacity: count) { buffer, initialized in
                for i in 0 ..< count {
                    buffer[i] = StrokePoint(location: CGPoint(x: Double(x[i]) / Scale.location,
                                                              y: Double(y[i]) / Scale.location),
                                            force: Double(f[i]) / Scale.force,
                                            altitude: Double(alt[i]) / Scale.angle,
                                            azimuth: Double(az[i]) / Scale.angle,
                                            timestamp: base + Double(t[i]) / Scale.time)
                }
                initialized = count
            }
        }
        return Stroke(id: id, color: color, brush: brush, points: points, createdAt: createdAt)
    }
}

// MARK: - Bytes

private struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func reserve(_ count: Int) {
        bytes.reserveCapacity(count)
    }

    mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }

    mutating func append(_ other: some Collection<UInt8>) {
        bytes.append(contentsOf: other)
    }

    mutating func u8(_ v: UInt8) {
        bytes.append(v)
    }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }

    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }

    mutating func f32(_ v: Float) {
        u32(v.bitPattern)
    }

    mutating func f64(_ v: Double) {
        u64(v.bitPattern)
    }

    mutating func uuid(_ id: UUID) {
        withUnsafeBytes(of: id.uuid) { bytes.append(contentsOf: $0) }
    }

    @inline(__always)
    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func record(type: UInt8, _ payload: [UInt8]) {
        u8(type)
        varint(UInt64(payload.count))
        append(payload)
    }

    /// The first value, then deltas of `order` 1 (the change) or 2 (the change in the change), as
    /// zigzag varints.
    mutating func column(_ points: [StrokePoint], order: Int, _ value: (StrokePoint) -> Int64) {
        var previous: Int64 = 0, previousStep: Int64 = 0
        for (i, point) in points.enumerated() {
            let v = value(point)
            let step = v &- previous
            let d = order == 2 && i > 1 ? step &- previousStep : step
            varint(UInt64(bitPattern: (d &<< 1) ^ (d >> 63)))
            previous = v
            previousStep = step
        }
    }
}

/// Bounds-checked reads over a byte buffer; every overrun throws instead of trapping.
private struct ByteReader {
    private let base: UnsafePointer<UInt8>?
    private let count: Int
    private var offset = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
        count = buffer.count
    }

    var remaining: Int {
        count - offset
    }

    mutating func slice(_ size: Int) throws -> UnsafeRawBufferPointer {
        guard size >= 0, size <= remaining else { throw InkFileError.truncated }
        defer { offset += size }
        return UnsafeRawBufferPointer(start: base.map { $0 + offset }, count: size)
    }

    mutating func bytes(_ size: Int) throws -> UnsafeRawBufferPointer {
        try slice(size)
    }

    @inline(__always)
    mutating func u8() throws -> UInt8 {
        guard offset < count, let base else { throw InkFileError.truncated }
        defer { offset += 1 }
        return base[offset]
    }

    private mutating func little(_ size: Int) throws -> UInt64 {
        let b = try slice(size)
        var v: UInt64 = 0
        for i in 0 ..< size {
            v |= UInt64(b[i]) << UInt64(8 * i)
        }
        return v
    }

    mutating func u16() throws -> UInt16 {
        try UInt16(truncatingIfNeeded: little(2))
    }

    mutating func u32() throws -> UInt32 {
        try UInt32(truncatingIfNeeded: little(4))
    }

    /// Widened to `Double`, so every float goes through `finite(_:)`.
    mutating func f32() throws -> Double {
        try Double(Float(bitPattern: u32()))
    }

    mutating func f64() throws -> Double {
        try Double(bitPattern: little(8))
    }

    mutating func uuid() throws -> UUID {
        let b = try slice(16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    func finite(_ v: Double) throws -> Double {
        guard v.isFinite else { throw InkFileError.corrupt("non-finite number") }
        return v
    }

    @inline(__always)
    mutating func varint() throws -> UInt64 {
        let first = try u8()
        if first < 0x80 {
            return UInt64(first)
        }
        var v = UInt64(first & 0x7F)
        var shift: UInt64 = 7
        while true {
            let byte = try u8()
            guard shift < 63 || byte <= 1 else { throw InkFileError.corrupt("varint overflow") }
            v |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 {
                return v
            }
            shift += 7
        }
    }

    /// A record length: must fit in what's left.
    mutating func length() throws -> Int {
        let v = try varint()
        guard v <= UInt64(remaining) else { throw InkFileError.truncated }
        return Int(v)
    }

    /// An element count, checked against what's left so a corrupt count can't force a huge allocation.
    mutating func count(minimumBytesEach: Int) throws -> Int {
        let v = try varint()
        guard v <= UInt64(remaining / minimumBytesEach) else { throw InkFileError.truncated }
        return Int(v)
    }

    /// Inverse of `ByteWriter.column`; wraps rather than traps on overflow.
    mutating func column(_ n: Int, order: Int, into values: inout [Int64]) throws {
        if values.count < n {
            values = [Int64](repeating: 0, count: max(n, values.count * 2))
        }
        guard n > 0 else { return }
        guard let base else { throw InkFileError.truncated }
        // The hot loop of decoding: reads straight from the buffer, one bounds check per byte.
        var o = offset
        let end = count
        try values.withUnsafeMutableBufferPointer { out in
            var previous: Int64 = 0, previousStep: Int64 = 0
            for i in 0 ..< n {
                guard o < end else { throw InkFileError.truncated }
                var u = UInt64(base[o])
                o += 1
                if u >= 0x80 {
                    u &= 0x7F
                    var shift: UInt64 = 7
                    while true {
                        guard o < end else { throw InkFileError.truncated }
                        let byte = base[o]
                        o += 1
                        guard shift < 63 || byte <= 1 else { throw InkFileError.corrupt("varint overflow") }
                        u |= UInt64(byte & 0x7F) << shift
                        if byte < 0x80 {
                            break
                        }
                        shift += 7
                    }
                }
                let d = Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
                let step = order == 2 && i > 1 ? previousStep &+ d : d
                previous = previous &+ step
                previousStep = step
                out[i] = previous
            }
        }
        offset = o
    }
}

/// CRC-32 (IEEE, as zlib and PNG use it), four bytes at a time.
struct CRC32 {
    /// `tables[k][b]`: the CRC of byte `b` followed by `k` zero bytes.
    private static let tables: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 4 * 256)
        for n in 0 ..< 256 {
            var c = UInt32(n)
            for _ in 0 ..< 8 {
                c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            t[n] = c
        }
        for n in 0 ..< 256 {
            for k in 1 ..< 4 {
                let c = t[(k - 1) * 256 + n]
                t[k * 256 + n] = t[Int(c & 0xFF)] ^ (c >> 8)
            }
        }
        return t
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 {
        state ^ 0xFFFF_FFFF
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let p = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var c = state
        Self.tables.withUnsafeBufferPointer { tables in
            let t = tables.baseAddress!
            var i = 0
            let n = bytes.count
            while i + 4 <= n {
                c ^= UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
                c = t[768 + Int(c & 0xFF)] ^ t[512 + Int((c >> 8) & 0xFF)]
                    ^ t[256 + Int((c >> 16) & 0xFF)] ^ t[Int(c >> 24)]
                i += 4
            }
            while i < n {
                c = t[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8)
                i += 1
            }
        }
        state = c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }
}
