// Copyright © 2026 Eigen Labs.
import Foundation
import zlib

/// One zlib stream read across input segments (consecutive PNG IDAT payloads).
/// zlib verifies the stream header and its Adler-32 trailer; `finish` also
/// requires the stream to end exactly at the end of the last segment, so a
/// stream that inflates to more than the declared raster is rejected.
/// The segments must stay valid for the inflater's lifetime.
final class NemotronSuperInflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var segments: ArraySlice<UnsafeRawBufferPointer>
    private var ended = false

    init(segments: [UnsafeRawBufferPointer]) throws {
        // Assigned only once zlib accepted it: a throwing initializer that
        // already set every property runs deinit, which would free it again.
        stream = try makeInflateStream()
        self.segments = segments[...]
    }

    deinit { freeInflateStream(stream) }

    /// Fills exactly `count` bytes; a stream ending earlier is truncated data.
    func read(into output: UnsafeMutablePointer<UInt8>, count: Int) throws {
        guard !ended, count >= 0, count <= Int(UInt32.max) else {
            throw NemotronSuperImageDecode.Failure.invalidRaster
        }
        stream.pointee.next_out = output
        stream.pointee.avail_out = UInt32(count)
        while stream.pointee.avail_out > 0 {
            if try step(), stream.pointee.avail_out > 0 {
                throw NemotronSuperImageDecode.Failure.invalidRaster
            }
        }
    }

    func finish() throws {
        var scratch: UInt8 = 0
        while !ended {
            try withUnsafeMutablePointer(to: &scratch) { pointer in
                stream.pointee.next_out = pointer
                stream.pointee.avail_out = 1
                _ = try step()
                guard stream.pointee.avail_out == 1 else { throw NemotronSuperImageDecode.Failure.invalidRaster }
            }
        }
        guard stream.pointee.avail_in == 0, segments.allSatisfy(\.isEmpty) else {
            throw NemotronSuperImageDecode.Failure.invalidRaster
        }
    }

    /// One inflate call; returns true at the end of the zlib stream.
    private func step() throws -> Bool {
        if stream.pointee.avail_in == 0, let next = segments.popFirst() {
            stream.pointee.next_in = UnsafeMutablePointer(
                mutating: next.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.pointee.avail_in = UInt32(next.count)
        }
        let input = stream.pointee.avail_in, output = stream.pointee.avail_out
        let status = inflate(stream, Z_NO_FLUSH)
        if status == Z_STREAM_END { ended = true; return true }
        guard status == Z_OK || status == Z_BUF_ERROR else {
            throw NemotronSuperImageDecode.Failure.invalidRaster
        }
        // No progress is only legal while another segment can supply input.
        if stream.pointee.avail_in == input, stream.pointee.avail_out == output,
           input > 0 || segments.isEmpty {
            throw NemotronSuperImageDecode.Failure.invalidRaster
        }
        return false
    }
}

/// Python `zlib.decompressobj().decompress(data, limit)` as Pillow's
/// `_safe_zlib_decompress` uses it, for the compressed text and ICC chunks of
/// one PNG. One z_stream and scratch buffer serve every chunk, and the chunks'
/// output together may not exceed `budget` bytes.
final class NemotronSuperChunkInflater {
    enum Result { case output(Data, complete: Bool), tooLarge, corrupt }

    private static let scratchBytes = 64 * 1024
    private let stream: UnsafeMutablePointer<z_stream>
    private let scratch: UnsafeMutablePointer<UInt8>
    private var remaining: Int

    init(budget: Int) throws {
        stream = try makeInflateStream()
        scratch = .allocate(capacity: Self.scratchBytes)
        remaining = budget
    }

    deinit {
        freeInflateStream(stream)
        scratch.deallocate()
    }

    /// Output stops at `limit`; input still unconsumed there is Pillow's "too
    /// large" refusal, as is any output beyond the remaining budget, which is
    /// charged even when Pillow would discard the text. Truncated input yields
    /// its partial output; a zlib error is `corrupt`. Empty input is empty output.
    func decompress(_ input: UnsafeRawBufferPointer, limit: Int) -> Result {
        guard let base = input.baseAddress, !input.isEmpty, input.count <= Int(UInt32.max) else {
            return .output(Data(), complete: false)
        }
        guard remaining >= 0 else { return .tooLarge }
        guard inflateReset(stream) == Z_OK else { return .corrupt }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = UInt32(input.count)
        var output = Data()
        while true {
            guard output.count < limit else {
                return stream.pointee.avail_in > 0 ? .tooLarge : .output(output, complete: false)
            }
            // One byte past the budget is enough to tell that it is exceeded.
            let room = min(Self.scratchBytes, limit - output.count, remaining + 1)
            stream.pointee.next_out = scratch
            stream.pointee.avail_out = UInt32(room)
            let status = inflate(stream, Z_NO_FLUSH)
            let produced = room - Int(stream.pointee.avail_out)
            remaining -= produced
            guard remaining >= 0 else { return .tooLarge }
            output.append(scratch, count: produced)
            switch status {
            case Z_STREAM_END: return .output(output, complete: true)
            case Z_OK: continue
            // With output room left, no progress means the input ran out.
            case Z_BUF_ERROR: return .output(output, complete: false)
            default: return .corrupt
            }
        }
    }
}

/// A heap z_stream ready for inflate: zlib keeps a back-pointer to it, so it
/// must not move. Nothing stays allocated when zlib refuses it.
private func makeInflateStream() throws -> UnsafeMutablePointer<z_stream> {
    let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    stream.initialize(to: z_stream())
    guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        stream.deinitialize(count: 1)
        stream.deallocate()
        throw NemotronSuperImageDecode.Failure.invalidRaster
    }
    return stream
}

private func freeInflateStream(_ stream: UnsafeMutablePointer<z_stream>) {
    inflateEnd(stream)
    stream.deinitialize(count: 1)
    stream.deallocate()
}
