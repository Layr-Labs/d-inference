import Foundation

/// One fixed transfer: big-endian length, unchanged payload, complete zero tail.
/// This provides framing only. The caller still validates the strict payload
/// schema, scope, rank, ordinal and operation before consuming any control.
enum PaddedControlFrame {
    static let byteCount = 16_384
    static let prefixByteCount = 4
    static let maximumPayloadBytes = byteCount - prefixByteCount
    // Serialized send/receive: encoded frame plus original/extracted JSON.
    static let hostAllowanceBytes = 2 * byteCount

    enum Failure: Error, Equatable {
        case invalidPayloadLength, invalidFrameLength, nonzeroPadding
    }

    static func encode(_ payload: Data) throws -> Data {
        guard (1...maximumPayloadBytes).contains(payload.count) else {
            throw Failure.invalidPayloadLength
        }
        var frame = Data(repeating: 0, count: byteCount)
        frame.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let count = UInt32(payload.count)
            for index in 0..<prefixByteCount {
                bytes[index] = UInt8(truncatingIfNeeded: count >> (8 * (3-index)))
            }
            payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                bytes.baseAddress!.advanced(by: prefixByteCount)
                    .copyMemory(from: source.baseAddress!, byteCount: payload.count)
            }
        }
        return frame
    }

    static func decode(_ frame: Data) throws -> Data {
        guard frame.count == byteCount else { throw Failure.invalidFrameLength }
        return try frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var count: UInt32 = 0
            for index in 0..<prefixByteCount { count = (count << 8) | UInt32(bytes[index]) }
            guard count > 0, count <= UInt32(maximumPayloadBytes) else {
                throw Failure.invalidPayloadLength
            }
            let end = prefixByteCount + Int(count)
            guard bytes[end..<byteCount].allSatisfy({ $0 == 0 }) else { throw Failure.nonzeroPadding }
            // Copy only after both length and the entire padding are checked.
            // Raw-buffer indices also handle Data slices with nonzero startIndex.
            return Data(bytes: bytes.baseAddress!.advanced(by: prefixByteCount), count: Int(count))
        }
    }
}
