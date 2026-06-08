import Foundation
import Crypto

// MARK: - Request Types

public struct ChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let temperature: Float?
    public let top_p: Float?
    public let top_k: Int?
    public let max_tokens: Int?
    public let repetition_penalty: Float?
    public let presence_penalty: Float?
    public let frequency_penalty: Float?
    public let stream: Bool?
    /// Stop sequences. Wire-compatible with both single-string and array forms.
    public let stop: StopSequences?
    /// Sampler RNG seed for deterministic generation. Optional.
    public let seed: UInt64?
    /// OpenAI tools spec. Pass-through only; we do not invoke tools server-side.
    public let tools: [ToolDefinition]?
    /// Forces a particular tool to be called. Pass-through.
    public let tool_choice: ToolChoice?
    /// `{"type": "json_object"}` etc. Pass-through.
    public let response_format: ResponseFormat?
    /// User identifier for rate-limit / abuse tracking.
    public let user: String?
    /// OpenAI-compatible opaque per-consumer cache key. When present, scopes
    /// the prefix cache so a cached prefix for one consumer can't be hit by
    /// another (closes the TB-007 cross-tenant prefix-sharing channel for the
    /// checkpoint tier). Rides INSIDE the E2E-sealed body, so the coordinator
    /// never sees it; the provider reads it after decryption.
    public let prompt_cache_key: String?

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Float? = nil,
        top_p: Float? = nil,
        top_k: Int? = nil,
        max_tokens: Int? = nil,
        repetition_penalty: Float? = nil,
        presence_penalty: Float? = nil,
        frequency_penalty: Float? = nil,
        stream: Bool? = nil,
        stop: StopSequences? = nil,
        seed: UInt64? = nil,
        tools: [ToolDefinition]? = nil,
        tool_choice: ToolChoice? = nil,
        response_format: ResponseFormat? = nil,
        user: String? = nil,
        prompt_cache_key: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.top_p = top_p
        self.top_k = top_k
        self.max_tokens = max_tokens
        self.repetition_penalty = repetition_penalty
        self.presence_penalty = presence_penalty
        self.frequency_penalty = frequency_penalty
        self.stream = stream
        self.stop = stop
        self.seed = seed
        self.tools = tools
        self.tool_choice = tool_choice
        self.response_format = response_format
        self.user = user
        self.prompt_cache_key = prompt_cache_key
    }

    /// Per-tenant prefix-cache scope for this request. Policy (provider-only):
    /// `SHA256(prompt_cache_key)` when present, else `SHA256(user)` when
    /// present, else "" (unscoped — shared cache, current behavior). Hashing
    /// keeps the on-disk/in-memory scope opaque and fixed-width regardless of
    /// the raw key. Empty inputs (`""`) are treated as absent.
    public var cacheScope: String {
        if let k = prompt_cache_key, !k.isEmpty { return Self.scopeHash(k) }
        if let u = user, !u.isEmpty { return Self.scopeHash(u) }
        return ""
    }

    static func scopeHash(_ s: String) -> String {
        let d = SHA256.hash(data: Data(s.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }
}

/// `stop` accepts either a single string or an array of strings on the wire.
public enum StopSequences: Codable, Sendable, Equatable {
    case single(String)
    case multiple([String])

    public var asArray: [String] {
        switch self {
        case .single(let s): return [s]
        case .multiple(let arr): return arr
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .single(s)
            return
        }
        if let arr = try? container.decode([String].self) {
            self = .multiple(arr)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "stop must be a string or [string]"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let s): try container.encode(s)
        case .multiple(let arr): try container.encode(arr)
        }
    }
}

/// Pass-through OpenAI tool definition. We don't introspect the JSON schema.
public struct ToolDefinition: Codable, Sendable {
    public let type: String
    public let function: ToolFunction

    public init(type: String, function: ToolFunction) {
        self.type = type
        self.function = function
    }
}

public struct ToolFunction: Codable, Sendable {
    public let name: String
    public let description: String?
    public let parameters: AnyCodableJSON?

    public init(name: String, description: String? = nil, parameters: AnyCodableJSON? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// `tool_choice` accepts "none" | "auto" | "required" | an object selecting
/// a specific tool. We round-trip the wire form without normalizing.
public enum ToolChoice: Codable, Sendable, Equatable {
    case mode(String)
    case named(type: String, function: ToolChoiceFunction)

    public struct ToolChoiceFunction: Codable, Sendable, Equatable {
        public let name: String

        public init(name: String) { self.name = name }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .mode(s)
            return
        }
        struct Named: Decodable {
            let type: String
            let function: ToolChoiceFunction
        }
        if let n = try? container.decode(Named.self) {
            self = .named(type: n.type, function: n.function)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "tool_choice must be a string or {type, function}"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .mode(let s): try container.encode(s)
        case .named(let type, let function):
            struct Named: Encodable {
                let type: String
                let function: ToolChoiceFunction
            }
            try container.encode(Named(type: type, function: function))
        }
    }
}

/// `response_format` is a small object today: `{"type": "json_object"}` etc.
public struct ResponseFormat: Codable, Sendable, Equatable {
    public let type: String
    public init(type: String) { self.type = type }
}

/// AnyCodableJSON is an inert container for "we passed JSON through; do not
/// touch it." We use this for tool parameter schemas where the contents are
/// arbitrary nested JSON values that we never inspect.
public struct AnyCodableJSON: Codable, Sendable, Equatable {
    public let raw: Data

    public init(raw: Data) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        // Decode any JSON value, then re-serialize to canonical form so two
        // equal payloads compare equal across decode boundaries.
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) {
            self.raw = try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])
            return
        }
        // Fall back to JSONSerialization-style decode for the generic case.
        let any = try container.decode(JSONValueShim.self)
        self.raw = try JSONSerialization.data(withJSONObject: any.value, options: [.fragmentsAllowed])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let obj = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) ?? NSNull()
        try container.encode(JSONValueShim(value: obj))
    }
}

private struct JSONValueShim: Codable {
    let value: Any

    init(value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int64.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let a = try? container.decode([JSONValueShim].self) {
            self.value = a.map(\.value)
        } else if let o = try? container.decode([String: JSONValueShim].self) {
            self.value = o.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:                  try container.encodeNil()
        case let v as Bool:              try container.encode(v)
        case let v as Int:               try container.encode(v)
        case let v as Int64:             try container.encode(v)
        case let v as Double:            try container.encode(v)
        case let v as String:            try container.encode(v)
        case let v as [Any]:             try container.encode(v.map(JSONValueShim.init))
        case let v as [String: Any]:     try container.encode(v.mapValues(JSONValueShim.init))
        default:
            throw EncodingError.invalidValue(value, .init(
                codingPath: container.codingPath,
                debugDescription: "unsupported JSON type"
            ))
        }
    }
}

public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Response Types (Streaming)

public struct ChatCompletionChunk: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ChunkChoice]
    public let usage: ChunkUsage?

    public init(
        id: String,
        object: String = "chat.completion.chunk",
        created: Int,
        model: String,
        choices: [ChunkChoice],
        usage: ChunkUsage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

public struct ChunkChoice: Codable, Sendable {
    public let index: Int
    public let delta: ChunkDelta
    public let finish_reason: String?

    public init(index: Int, delta: ChunkDelta, finish_reason: String? = nil) {
        self.index = index
        self.delta = delta
        self.finish_reason = finish_reason
    }
}

public struct ChunkDelta: Codable, Sendable {
    public let role: String?
    public let content: String?

    public init(role: String? = nil, content: String? = nil) {
        self.role = role
        self.content = content
    }
}

public struct ChunkUsage: Codable, Sendable {
    public let prompt_tokens: Int
    public let completion_tokens: Int
    public let total_tokens: Int

    public init(prompt_tokens: Int, completion_tokens: Int) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = prompt_tokens + completion_tokens
    }
}

// MARK: - Response Types (Non-Streaming)

public struct ChatCompletionResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ResponseChoice]
    public let usage: ChunkUsage

    public init(
        id: String,
        object: String = "chat.completion",
        created: Int,
        model: String,
        choices: [ResponseChoice],
        usage: ChunkUsage
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

public struct ResponseChoice: Codable, Sendable {
    public let index: Int
    public let message: ResponseMessage
    public let finish_reason: String

    public init(index: Int, message: ResponseMessage, finish_reason: String) {
        self.index = index
        self.message = message
        self.finish_reason = finish_reason
    }
}

public struct ResponseMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String = "assistant", content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - SSE Chunk Wrapper

public struct SSEChunk: Sendable {
    public let data: String

    public init(data: String) {
        self.data = data
    }

    public var formatted: String {
        "data: \(data)\n\n"
    }

    public static let done = SSEChunk(data: "[DONE]")
}

// MARK: - Errors

public enum InferenceError: Error, Sendable {
    case noModelLoaded
    case modelLoadFailed(String)
    case generationFailed(String)
    case invalidModelDirectory(String)
    case unsupportedRole(String)
}
