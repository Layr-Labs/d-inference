import Foundation
import NIOCore

/// How deeply a request's JSON may nest before any recursive parser reads it.
///
/// `JSONSerialization`, `JSONDecoder` and the provider's own schema walks
/// recurse once per object or array, and request handling runs on Swift
/// concurrency's cooperative threads, whose stacks are 512 KiB. A body nested
/// a few hundred levels deep, only a few KB long, exhausts that stack and
/// kills the process (SIGBUS) below `JSONSerialization`'s own 512-level limit.
/// This scan counts levels without recursing, so such a body is refused first.
enum JSONNestingLimit {
    /// A tool schema at the constraint compiler's 16 levels nests about 40
    /// deep in a request; nothing real comes near this.
    static let maximumDepth = 64

    static let tooDeep = DecodingError.dataCorrupted(.init(
        codingPath: [], debugDescription: "JSON nests deeper than \(maximumDepth) levels"))

    static func exceeds(_ data: Data, limit: Int = maximumDepth) -> Bool {
        data.withUnsafeBytes { exceeds($0, limit: limit) }
    }

    static func exceeds(_ buffer: ByteBuffer, limit: Int = maximumDepth) -> Bool {
        buffer.withUnsafeReadableBytes { exceeds($0, limit: limit) }
    }

    /// Whether the text opens more than `limit` objects and arrays at once.
    /// Brackets inside strings do not count; the text is not otherwise
    /// validated, so a malformed body is left to its parser.
    static func exceeds(_ bytes: UnsafeRawBufferPointer, limit: Int = maximumDepth) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth > limit { return true }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
        return false
    }
}
