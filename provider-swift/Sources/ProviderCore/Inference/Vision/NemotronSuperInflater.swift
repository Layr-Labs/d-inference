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
        self.segments = segments[...]
        // zlib keeps a back-pointer to the z_stream, so it must not move.
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw NemotronSuperImageDecode.Failure.invalidRaster
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

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

    enum PillowDecompression { case output(Data, complete: Bool), tooLarge, corrupt }

    /// Python `zlib.decompressobj().decompress(data, limit)` as Pillow's
    /// `_safe_zlib_decompress` uses it: output stops at `limit`, and input still
    /// unconsumed there is Pillow's "too large" refusal. Truncated input yields
    /// its partial output; a zlib error is `corrupt`. Empty input is empty output.
    static func pillowDecompress(_ input: UnsafeRawBufferPointer, limit: Int) -> PillowDecompression {
        guard let base = input.baseAddress, !input.isEmpty, input.count <= Int(UInt32.max) else {
            return .output(Data(), complete: false)
        }
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer {
            inflateEnd(stream)
            stream.deinitialize(count: 1)
            stream.deallocate()
        }
        guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return .corrupt }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = UInt32(input.count)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let room = min(chunk.count, limit - output.count)
            guard room > 0 else { return stream.pointee.avail_in > 0 ? .tooLarge : .output(output, complete: false) }
            let (status, produced) = chunk.withUnsafeMutableBufferPointer { buffer -> (Int32, Int) in
                stream.pointee.next_out = buffer.baseAddress
                stream.pointee.avail_out = UInt32(room)
                let status = inflate(stream, Z_NO_FLUSH)
                return (status, room - Int(stream.pointee.avail_out))
            }
            output.append(contentsOf: chunk[0..<produced])
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
