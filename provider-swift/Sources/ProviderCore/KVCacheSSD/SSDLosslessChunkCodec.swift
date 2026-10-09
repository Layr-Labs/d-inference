import Compression
import Foundation

/// A reversible byte permutation and bounded LZ4 codec. The two-byte frame is
/// inside the authenticated ciphertext; the tensor's declared native byte count
/// remains the allocation bound. Incompressible data uses the raw frame.
enum SSDLosslessChunkCodec {
    static let identity = "byteplanes-lz4-v1"
    static let frameBytes = 2

    static func encode(_ native: Data, elementBytes: Int) throws -> Data {
        guard [1, 2, 4].contains(elementBytes), native.count % elementBytes == 0 else {
            throw SSDBlockStoreError.malformedHeader("invalid compression element width")
        }
        guard native.count <= Int.max - frameBytes else {
            throw SSDBlockStoreError.sizeOverflow("lossless frame overflow")
        }
        guard !native.isEmpty else { return Data([0, 1]) }

        // Compress directly into the framed destination. A separate encoded
        // buffer followed by a frame copy would retain four segment-sized
        // buffers at once; this path needs only source, shuffle and destination.
        var frame = Data(count: native.count + frameBytes)
        let count = compressLZ4(native, elementBytes: elementBytes, into: &frame)
        if count > 0, count < native.count {
            frame[0] = 1
            frame[1] = UInt8(elementBytes)
            frame.removeSubrange((frameBytes + count)..<frame.count)
        } else {
            frame[0] = 0
            frame[1] = 1
            frame.withUnsafeMutableBytes { destination in
                native.withUnsafeBytes { source in
                    destination.baseAddress!.advanced(by: frameBytes).copyMemory(
                        from: source.baseAddress!, byteCount: native.count)
                }
            }
        }
        return frame
    }

    private static func compressLZ4(_ native: Data, elementBytes: Int, into frame: inout Data) -> Int {
        let transformed = elementBytes == 1 ? native : transpose(native, width: elementBytes, inverse: false)
        let scratchBytes = compression_encode_scratch_buffer_size(COMPRESSION_LZ4)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(1, scratchBytes), alignment: 16)
        defer { scratch.deallocate() }
        return frame.withUnsafeMutableBytes { destination in
            transformed.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!.advanced(by: frameBytes), native.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, native.count, scratch, COMPRESSION_LZ4)
            }
        }
    }

    static func decode(_ frame: Data, nativeBytes: Int) throws -> Data {
        guard nativeBytes >= 0, nativeBytes <= Int.max - frameBytes,
            frame.count >= frameBytes, frame.count <= nativeBytes + frameBytes else {
            throw SSDBlockStoreError.malformedHeader("invalid lossless chunk size")
        }
        let encoding = frame[frame.startIndex]
        let width = Int(frame[frame.startIndex + 1])
        guard [1, 2, 4].contains(width), nativeBytes % width == 0 else {
            throw SSDBlockStoreError.malformedHeader("invalid lossless chunk element width")
        }
        if encoding == 0 {
            guard width == 1, frame.count == nativeBytes + frameBytes else {
                throw SSDBlockStoreError.malformedHeader("invalid raw lossless chunk")
            }
            return Data(frame.dropFirst(frameBytes))
        }
        guard encoding == 1, nativeBytes > 0, frame.count > frameBytes else {
            throw SSDBlockStoreError.malformedHeader("unsupported lossless chunk encoding")
        }
        // One extra output byte distinguishes an oversized stream from one
        // that happens to fill the expected destination before reaching END.
        var decoded = Data(count: nativeBytes + 1)
        try decoded.withUnsafeMutableBytes { destination in
            try frame.withUnsafeBytes { source in
                var stream = compression_stream(
                    dst_ptr: destination.bindMemory(to: UInt8.self).baseAddress!, dst_size: nativeBytes + 1,
                    src_ptr: source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: frameBytes),
                    src_size: frame.count - frameBytes, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK else {
                    throw SSDBlockStoreError.malformedHeader("lossless decoder initialization failed")
                }
                defer { compression_stream_destroy(&stream) }
                stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                stream.dst_size = nativeBytes + 1
                stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: frameBytes)
                stream.src_size = frame.count - frameBytes
                while true {
                    let previousSource = stream.src_size
                    let previousDestination = stream.dst_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if status == COMPRESSION_STATUS_END {
                        guard stream.src_size == 0, stream.dst_size == 1 else {
                            throw SSDBlockStoreError.malformedHeader("lossless stream size or trailing bytes mismatch")
                        }
                        break
                    }
                    guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                        stream.src_size < previousSource || stream.dst_size < previousDestination else {
                        throw SSDBlockStoreError.malformedHeader("incomplete or oversized lossless stream")
                    }
                }
            }
        }
        decoded.removeLast()
        return width == 1 ? decoded : transpose(decoded, width: width, inverse: true)
    }

    private static func transpose(_ bytes: Data, width: Int, inverse: Bool) -> Data {
        let elements = bytes.count / width
        var result = Data(count: bytes.count)
        result.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                let input = source.bindMemory(to: UInt8.self)
                let output = destination.bindMemory(to: UInt8.self)
                for plane in 0..<width {
                    for element in 0..<elements {
                        let interleaved = element * width + plane
                        let planar = plane * elements + element
                        output[inverse ? interleaved : planar] = input[inverse ? planar : interleaved]
                    }
                }
            }
        }
        return result
    }
}
