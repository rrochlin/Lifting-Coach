import Compression
import CryptoKit
import Foundation

/// A streaming gzip codec over Apple's `Compression` framework.
///
/// `Compression` speaks raw DEFLATE; `COMPRESSION_ZLIB` names the algorithm, not
/// the container. The ten-byte header and eight-byte trailer handled here are
/// what make the output a file `gunzip` and Python's `gzip` module accept — and
/// the thing reading a snapshot in production is a Python Lambda, so that
/// interoperability is the whole point of not just shipping raw DEFLATE.
///
/// Both directions stream in 64 KB windows rather than working on a whole
/// `Data`. The input is a training log that grows for as long as the lifter
/// keeps training, compression runs on a phone that is usually being
/// backgrounded when it does, and a restore runs on a device that has just
/// downloaded the file.
enum Gzip {
    struct Output {
        let byteCount: Int
        let sha256: String
    }

    enum Failure: Error, Equatable {
        case notAGzipArchive
        /// The trailer's CRC-32 or length disagrees with what was decoded — the
        /// file is truncated or corrupt, and half a training log is worse than
        /// none of one.
        case corrupt
        case streamFailed
        case couldNotCreateFile(String)
    }

    private static let bufferSize = 64 * 1024

    // MARK: Compress

    static func compress(fileAt source: URL, to destination: URL) throws -> Output {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try makeFile(at: destination)
        defer { try? output.close() }

        var hasher = SHA256()
        var written = 0
        func emit(_ data: Data) throws {
            guard !data.isEmpty else { return }
            try output.write(contentsOf: data)
            hasher.update(data: data)
            written += data.count
        }

        // magic, DEFLATE, no flags, mtime 0, no extra flags, OS unknown.
        // A zero mtime is deliberate: the same database has to compress to the
        // same bytes twice, or an unchanged snapshot looks like a changed one
        // and the S3 ETag stops meaning anything.
        try emit(Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]))

        var crc = CRC32()
        var rawCount: UInt64 = 0

        try withStream(COMPRESSION_STREAM_ENCODE) { stream, src, dst in
            var flags: Int32 = 0
            var atEnd = false

            while true {
                if stream.pointee.src_size == 0 && !atEnd {
                    let chunk = try input.read(upToCount: bufferSize) ?? Data()
                    if chunk.isEmpty {
                        atEnd = true
                        flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    } else {
                        chunk.withUnsafeBytes { raw in
                            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                                src.update(from: base, count: chunk.count)
                            }
                            crc.update(raw)
                        }
                        rawCount += UInt64(chunk.count)
                        stream.pointee.src_ptr = UnsafePointer(src)
                        stream.pointee.src_size = chunk.count
                    }
                }

                let status = compression_stream_process(stream, flags)
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw Failure.streamFailed
                }

                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    try emit(Data(bytes: dst, count: produced))
                    stream.pointee.dst_ptr = dst
                    stream.pointee.dst_size = bufferSize
                }

                if status == COMPRESSION_STATUS_END { break }
            }
        }

        // CRC-32 of the uncompressed bytes, then their length mod 2^32.
        var trailer = Data()
        withUnsafeBytes(of: crc.checksum.littleEndian) { trailer.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: rawCount).littleEndian) {
            trailer.append(contentsOf: $0)
        }
        try emit(trailer)

        return Output(byteCount: written, sha256: hasher.finalize().hexadecimal)
    }

    // MARK: Decompress

    /// Inflates `source` into `destination`, verifying the trailer.
    ///
    /// The trailer check is the reason this doesn't just shell the bytes through
    /// the decoder and hope: a truncated download inflates perfectly happily
    /// into a shorter, structurally valid SQLite file, and restoring one of
    /// those would silently discard the tail of a training history.
    @discardableResult
    static func decompress(fileAt source: URL, to destination: URL) throws -> Int {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        let totalSize = try input.seekToEnd()
        // Ten bytes of minimum header plus eight of trailer, and DEFLATE never
        // emits nothing for a non-empty stream.
        guard totalSize >= 18 else { throw Failure.notAGzipArchive }

        try input.seek(toOffset: totalSize - 8)
        let trailer = try input.read(upToCount: 8) ?? Data()
        guard trailer.count == 8 else { throw Failure.notAGzipArchive }
        let expectedCRC = trailer.prefix(4).littleEndianUInt32
        let expectedSize = trailer.suffix(4).littleEndianUInt32

        try input.seek(toOffset: 0)
        let bodyStart = try headerLength(of: input)
        let bodyEnd = totalSize - 8
        guard bodyStart < bodyEnd else { throw Failure.notAGzipArchive }

        let output = try makeFile(at: destination)
        defer { try? output.close() }

        var crc = CRC32()
        var rawCount: UInt64 = 0
        try input.seek(toOffset: bodyStart)
        var remaining = Int(bodyEnd - bodyStart)

        try withStream(COMPRESSION_STREAM_DECODE) { stream, src, dst in
            var flags: Int32 = 0

            while true {
                if stream.pointee.src_size == 0 && remaining > 0 {
                    let want = min(bufferSize, remaining)
                    let chunk = try input.read(upToCount: want) ?? Data()
                    guard !chunk.isEmpty else { throw Failure.corrupt }
                    chunk.withUnsafeBytes { raw in
                        if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                            src.update(from: base, count: chunk.count)
                        }
                    }
                    remaining -= chunk.count
                    stream.pointee.src_ptr = UnsafePointer(src)
                    stream.pointee.src_size = chunk.count
                    if remaining == 0 {
                        flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    }
                }

                let status = compression_stream_process(stream, flags)
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw Failure.corrupt
                }

                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    let data = Data(bytes: dst, count: produced)
                    try output.write(contentsOf: data)
                    data.withUnsafeBytes { crc.update($0) }
                    rawCount += UInt64(produced)
                    stream.pointee.dst_ptr = dst
                    stream.pointee.dst_size = bufferSize
                }

                if status == COMPRESSION_STATUS_END { break }
                // Out of input without the stream ending means the DEFLATE data
                // itself is short, which the trailer check alone wouldn't catch
                // before we'd already written a partial file.
                if remaining == 0 && produced == 0 && status == COMPRESSION_STATUS_OK {
                    throw Failure.corrupt
                }
            }
        }

        guard crc.checksum == expectedCRC,
              UInt32(truncatingIfNeeded: rawCount) == expectedSize else {
            throw Failure.corrupt
        }
        return Int(rawCount)
    }

    /// Walks the header's optional fields so a file written by any gzip
    /// implementation reads, not only by ours.
    private static func headerLength(of input: FileHandle) throws -> UInt64 {
        // Long enough for any header this will realistically meet; ours is 10.
        let head = try input.read(upToCount: 4096) ?? Data()
        let bytes = [UInt8](head)
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            throw Failure.notAGzipArchive
        }

        let flags = bytes[3]
        var offset = 10

        func requireByte() throws -> UInt8 {
            guard offset < bytes.count else { throw Failure.notAGzipArchive }
            defer { offset += 1 }
            return bytes[offset]
        }

        if flags & 0x04 != 0 { // FEXTRA
            let low = try requireByte(), high = try requireByte()
            offset += Int(UInt16(high) << 8 | UInt16(low))
        }
        if flags & 0x08 != 0 { // FNAME
            while try requireByte() != 0 {}
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while try requireByte() != 0 {}
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard offset <= bytes.count else { throw Failure.notAGzipArchive }
        return UInt64(offset)
    }

    // MARK: Plumbing

    private static func makeFile(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw Failure.couldNotCreateFile(url.path)
        }
        return try FileHandle(forWritingTo: url)
    }

    /// Runs `body` with an initialized encode/decode stream and the two owned
    /// buffers it needs.
    ///
    /// The buffers are allocated rather than borrowed from a `Data`, because the
    /// stream keeps `src_ptr` across calls and so it has to outlive the chunk
    /// that filled it.
    private static func withStream(
        _ operation: compression_stream_operation,
        _ body: (
            UnsafeMutablePointer<compression_stream>,
            UnsafeMutablePointer<UInt8>,
            UnsafeMutablePointer<UInt8>
        ) throws -> Void
    ) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(
            stream, operation, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            throw Failure.streamFailed
        }
        defer { compression_stream_destroy(stream) }

        let src = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { src.deallocate() }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }

        stream.pointee.src_ptr = UnsafePointer(src)
        stream.pointee.src_size = 0
        stream.pointee.dst_ptr = dst
        stream.pointee.dst_size = bufferSize

        try body(stream, src, dst)
    }
}

/// The CRC-32 gzip's trailer wants. Not a checksum anyone here chose — it is
/// part of the container format, and `gunzip` rejects a file whose trailer
/// disagrees with its contents.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = value
        for byte in bytes {
            c = Self.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        value = c
    }

    var checksum: UInt32 { value ^ 0xFFFF_FFFF }
}

extension Data {
    var littleEndianUInt32: UInt32 {
        reduce(into: (value: UInt32(0), shift: UInt32(0))) { state, byte in
            state.value |= UInt32(byte) << state.shift
            state.shift += 8
        }.value
    }
}

extension Sequence<UInt8> {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
