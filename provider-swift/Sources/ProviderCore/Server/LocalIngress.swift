import HTTPTypes
import Hummingbird
import NIOCore

/// The local API's routes that have limits or handling of their own, as the SDK router resolves a request to them.
///
/// The router's trie splits a path on `/` and drops its empty segments (Hummingbird's `RouterTrie.resolve`), so
/// `/v1/chat/completions/` and `//v1/chat/completions` are the route `/v1/chat/completions`. A check that compares
/// the path as the client wrote it misses those spellings, and the SDK's handler then serves them with no limit but
/// its own body ceiling. So neither the limits nor the local router compare a path: each asks for the request's
/// `LocalRoute`, which reads the path the way the trie does.
enum LocalRoute: Sendable, Equatable {
    /// `GET /v1/models`, `/models`.
    case models
    /// `POST /v1/chat/completions`, `/chat/completions`.
    case chatCompletions
    /// `POST /v1/chat/completions/batch`.
    case chatCompletionsBatch
    /// `POST /v1/responses`, `/responses`.
    case responses
    /// `POST /v1/completions`, `/completions`.
    case completions
    /// `POST /apply-template`.
    case applyTemplate
    /// Every other method and path, whether the SDK router serves it or not: the default limits.
    case other

    init(method: HTTPRequest.Method, path: String) {
        let resolved = "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        switch (method, resolved) {
        case (.get, "/v1/models"), (.get, "/models"): self = .models
        case (.post, "/v1/chat/completions"), (.post, "/chat/completions"): self = .chatCompletions
        case (.post, "/v1/chat/completions/batch"): self = .chatCompletionsBatch
        case (.post, "/v1/responses"), (.post, "/responses"): self = .responses
        case (.post, "/v1/completions"), (.post, "/completions"): self = .completions
        case (.post, "/apply-template"): self = .applyTemplate
        default: self = .other
        }
    }

    /// The most body bytes the route reads. Only the routes that carry inline media raise the default.
    var bodyCeiling: Int {
        switch self {
        case .chatCompletions, .chatCompletionsBatch: return localInferenceMaxUploadBytes
        case .models, .responses, .completions, .applyTemplate, .other: return LocalIngress.defaultBodyCeiling
        }
    }

    /// The most items the route's body, a JSON array, may hold; nil for a route whose body is no list.
    var maxItems: Int? {
        switch self {
        case .chatCompletionsBatch: return localInferenceMaxBatchRequests
        case .models, .chatCompletions, .responses, .completions, .applyTemplate, .other: return nil
        }
    }

    /// The coordinator path the local router may pass the route's request on to; nil for a route only this Mac
    /// serves (models, health, tokenizer utilities, embeddings, batches, stored responses).
    var upstreamPath: String? {
        switch self {
        case .chatCompletions: return "/v1/chat/completions"
        case .completions: return "/v1/completions"
        case .responses: return "/v1/responses"
        case .models, .chatCompletionsBatch, .applyTemplate, .other: return nil
        }
    }
}

/// The local API's request limits, applied in one place to the body of every request that may carry one.
///
/// Whoever reads a request's body, the engine's routes (`LocalChatUploadResponder`) or the local router before a
/// pass-on (`LocalRouter.route`), takes it from `admit`. A route with no limits of its own (`LocalRoute.other`: one
/// the SDK adds later, or a path no one serves) gets the default ones, so a new route is bounded before anyone
/// thinks of it.
enum LocalIngress {
    /// The body ceiling of a route that raises none: Hummingbird's own for `BasicRequestContext`, which the SDK's
    /// routes decode within.
    static let defaultBodyCeiling = 2 * 1024 * 1024

    /// Why a request's body was refused, for each caller to answer in its own envelope.
    enum Refusal: Sendable, Equatable {
        case bodyTooLarge(ceiling: Int)
        /// Nested past `JSONNestingLimit`, or holding a NUL byte.
        case nestedTooDeep
        case tooManyItems(limit: Int)

        var status: HTTPResponse.Status {
            switch self {
            case .bodyTooLarge: return .contentTooLarge
            case .nestedTooDeep, .tooManyItems: return .badRequest
            }
        }

        var message: String {
            switch self {
            case .bodyTooLarge(let ceiling):
                return "request body exceeds the \(ceiling / (1024 * 1024)) MiB local endpoint limit"
            case .nestedTooDeep:
                return JSONNestingLimit.refusalMessage
            case .tooManyItems(let limit):
                return "batch exceeds the \(limit)-request local endpoint limit"
            }
        }

        /// The OpenAI error code, where the refusal has one.
        var code: String? {
            switch self {
            case .tooManyItems: return "batch_too_large"
            case .bodyTooLarge, .nestedTooDeep: return nil
            }
        }
    }

    enum Admission: Sendable {
        /// The whole body, within every limit of its route; the request now holds this same buffer. Empty for a
        /// GET or HEAD, whose body stays unread.
        case admitted(ByteBuffer)
        case refused(Refusal)
    }

    /// Collects `request`'s body up to its route's ceiling and refuses one over a limit, before any parser reads it:
    /// the ceiling first, then the nesting scan (the parsers recurse once per level on this task's stack), then the
    /// item count (a list's items are counted, not decoded).
    ///
    /// No GET or HEAD route reads a body, so theirs is left unread, as the SDK router leaves it. Every other method
    /// is held to its route's limits, whether a route serves it or not.
    static func admit(_ request: inout Request, as route: LocalRoute) async throws -> Admission {
        guard request.method != .get, request.method != .head else { return .admitted(ByteBuffer()) }
        let ceiling = route.bodyCeiling
        let body: ByteBuffer
        do {
            body = try await request.collectBody(upTo: ceiling)
        } catch is NIOTooManyBytesError {
            return .refused(.bodyTooLarge(ceiling: ceiling))
        }
        guard !JSONNestingLimit.refuses(body) else { return .refused(.nestedTooDeep) }
        if let limit = route.maxItems, itemCount(body) > limit { return .refused(.tooManyItems(limit: limit)) }
        return .admitted(body)
    }

    /// The items of a body's top-level JSON array, counted without decoding them: the array's own commas, skipping
    /// strings and nested values. A body that is not an array counts 0 and is left to the decoder.
    static func itemCount(_ buffer: ByteBuffer) -> Int {
        buffer.withUnsafeReadableBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            var depth = 0
            var commas = 0
            var hasItem = false
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
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    break
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    if depth == 0, byte != UInt8(ascii: "[") { return 0 }
                    if depth == 1 { hasItem = true }
                    depth += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 0 { return hasItem ? commas + 1 : 0 }
                case UInt8(ascii: ","):
                    if depth == 1 { commas += 1 }
                case UInt8(ascii: "\""):
                    if depth == 0 { return 0 }
                    if depth == 1 { hasItem = true }
                    inString = true
                default:
                    if depth == 0 { return 0 }
                    if depth == 1 { hasItem = true }
                }
            }
            return hasItem ? commas + 1 : 0
        }
    }
}
