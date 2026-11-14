import Foundation
import MLXLMServer
import NIOCore

/// How deeply a request's JSON may nest before any recursive parser reads it.
///
/// `JSONSerialization`, `JSONDecoder` and the provider's own schema walks
/// recurse once per object or array, and request handling runs on Swift
/// concurrency's cooperative threads, whose stacks are 512 KiB. A body nested
/// a few hundred levels deep, only a few KB long, exhausts that stack and
/// kills the process (SIGBUS) below `JSONSerialization`'s own 512-level limit.
/// This scan counts levels without recursing, so such a body is refused first.
/// Foundation's parsers also read UTF-16 and UTF-32 JSON, whose bytes this
/// scan could not count, so a body holding a NUL byte is refused too: no
/// UTF-8 JSON text has one, and every UTF-16 or UTF-32 one does.
enum JSONNestingLimit {
    /// A tool schema at the constraint compiler's 16 levels
    /// (`ToolConstraintSchema.maxDepth`) nests about 40 deep in a request;
    /// nothing real comes near this.
    static let maximumDepth = 64

    /// The local API's HTTP 400 message for a refused body.
    static let refusalMessage = "request JSON nests deeper than \(maximumDepth) levels or is not UTF-8"
    /// The local API's HTTP 400 message for refused tool-call arguments.
    static let argumentsRefusalMessage = "tool call arguments nest deeper than \(maximumDepth) levels or hold a NUL"

    static let refusal = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: refusalMessage))
    /// Refused tool-call arguments map to `invalid_tool_arguments`, as other
    /// unusable arguments do (`InferenceRefusalReason(chatDecodeFailure:)`).
    static let argumentsRefusal = DecodingError.dataCorrupted(.init(
        codingPath: ["messages", "tool_calls", "arguments"].map(RequestKey.init),
        debugDescription: argumentsRefusalMessage))

    static var redControlScanOff: Bool { true }

    static func refuses(_ data: Data) -> Bool {
        data.withUnsafeBytes { refuses($0) }
    }

    static func refuses(_ buffer: ByteBuffer) -> Bool {
        buffer.withUnsafeReadableBytes { refuses($0) }
    }

    /// Tool-call `arguments` are JSON inside a JSON string: the body scan
    /// skips them, and template rendering parses them recursively.
    static func refusesToolCallArguments(in messages: [OpenAIChatMessage]) -> Bool {
        messages.contains { message in
            (message.toolCalls ?? []).contains { refuses(Data($0.function.arguments.utf8)) }
        }
    }

    private struct RequestKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Whether the text holds a NUL byte or opens more than ``maximumDepth``
    /// objects and arrays at once. Brackets inside strings do not count; the
    /// text is not otherwise validated, so a malformed body is left to its parser.
    private static func refuses(_ bytes: UnsafeRawBufferPointer) -> Bool {
        // RED CONTROL ONLY (not for merge): the scan refuses nothing, so every guard lets
        // the body through as dev did.
        if redControlScanOff { return false }
        var depth = 0
        var inString = false
        var escaped = false
        for byte in bytes {
            if byte == 0 { return true }
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
                if depth > maximumDepth { return true }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
        return false
    }
}
