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
                let reachedEnd = try step()
                guard stream.pointee.avail_out == 1 else { throw NemotronSuperImageDecode.Failure.invalidRaster }
                ended = reachedEnd
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

    /// A complete zlib stream whose output must not exceed `limit` bytes.
    static func inflateAll(_ input: UnsafeRawBufferPointer, limit: Int) throws -> Data {
        let inflater = try NemotronSuperInflater(segments: [input])
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !inflater.ended {
            let produced = try chunk.withUnsafeMutableBufferPointer { buffer -> Int in
                inflater.stream.pointee.next_out = buffer.baseAddress
                inflater.stream.pointee.avail_out = UInt32(buffer.count)
                while inflater.stream.pointee.avail_out > 0, !(try inflater.step()) {}
                return buffer.count - Int(inflater.stream.pointee.avail_out)
            }
            guard produced <= limit - output.count else { throw NemotronSuperImageDecode.Failure.sizeLimit }
            output.append(contentsOf: chunk[0..<produced])
        }
        try inflater.finish()
        return output
    }
}
