import CryptoKit
import Foundation
public struct PrivateV2KeyMaterial: Sendable {
    public let requestKey: SymmetricKey
    public let responseKey: SymmetricKey

    public init(requestKey: SymmetricKey, responseKey: SymmetricKey) {
        self.requestKey = requestKey
        self.responseKey = responseKey
    }
}


public enum PrivateV2Crypto {
    public static func requestAAD(transcriptDigest: Data) throws -> Data {
        guard transcriptDigest.count == 32 else { throw PrivateV2Error.invalidLength }
        return transcriptDigest
    }

    public static func responseAAD(transcriptDigest: Data, sequence: UInt64) throws -> Data {
        guard transcriptDigest.count == 32 else { throw PrivateV2Error.invalidLength }
        var aad = transcriptDigest
        var bigEndian = sequence.bigEndian
        withUnsafeBytes(of: &bigEndian) { aad.append(contentsOf: $0) }
        return aad
    }

    /// AES-GCM wire ciphertext is encrypted bytes followed by the 16-byte tag;
    /// nonce is carried separately on the wire.
    public static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        nonce: Data,
        aad: Data
    ) throws -> Data {
        guard nonce.count == 12 else { throw PrivateV2Error.invalidLength }
        do {
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: try AES.GCM.Nonce(data: nonce),
                authenticating: aad)
            var output = sealed.ciphertext
            output.append(sealed.tag)
            return output
        } catch {
            throw PrivateV2Error.encryptionFailed
        }
    }

    public static func open(
        _ ciphertextAndTag: Data,
        key: SymmetricKey,
        nonce: Data,
        aad: Data
    ) throws -> Data {
        guard nonce.count == 12, ciphertextAndTag.count >= 16 else {
            throw PrivateV2Error.invalidLength
        }
        let split = ciphertextAndTag.count - 16
        do {
            let encryptedBytes = Data(ciphertextAndTag.prefix(split))
            let tagBytes = Data(ciphertextAndTag.suffix(16))
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: encryptedBytes,
                tag: tagBytes)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw PrivateV2Error.decryptionFailed
        }
    }

    public static func randomNonce() throws -> Data {
        let nonce = AES.GCM.Nonce()
        return nonce.withUnsafeBytes { Data($0) }
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

public final class PrivateV2ReplayLedger: @unchecked Sendable {
    private struct ClaimKey: Hashable {
        let leaseId: String
        let requestId: String
    }
    private let lock = NSLock()
    private let capacity: Int
    private var claimed: [ClaimKey: Date] = [:]

    public init(capacity: Int = PrivateV2Protocol.replayCapacity) {
        self.capacity = max(0, capacity)
    }

    public func claim(leaseId: String, requestId: String, expiresAt: Date, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        claimed = claimed.filter { $0.value > now }
        let key = ClaimKey(leaseId: leaseId, requestId: requestId)
        guard claimed[key] == nil else { throw PrivateV2Error.replay }
        guard claimed.count < capacity else { throw PrivateV2Error.replayCapacity }
        guard expiresAt > now else { throw PrivateV2Error.deadlineExpired }
        claimed[key] = expiresAt
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return claimed.count
    }

    public func removeAll() {
        lock.lock()
        claimed.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

public struct PrivateV2InnerRequest: Sendable {
    public let transcript: PrivateV2Transcript
    public let body: Data

    private struct Metadata: Decodable {
        let leaseId: String
        let requestId: String
        let routeId: String
        let endpoint: PrivateV2Endpoint
        let model: String
        let processCertificateDigest: String
        let releaseBinaryHash: String
        let modelManifestHash: String
        let releaseGeneration: UInt64
        let modelGeneration: UInt64
        let ownerBinding: String
        let requestedMaxOutputTokens: UInt64
        let requiresVision: Bool
        let routeMode: String
        let deadline: String
        let body: JSONValue

        enum CodingKeys: String, CodingKey {
            case leaseId = "lease_id"
            case requestId = "request_id"
            case routeId = "route_id"
            case endpoint, model
            case processCertificateDigest = "process_certificate_digest"
            case releaseBinaryHash = "release_binary_hash"
            case modelManifestHash = "model_manifest_hash"
            case releaseGeneration = "release_generation"
            case modelGeneration = "model_generation"
            case ownerBinding = "owner_binding"
            case requestedMaxOutputTokens = "requested_max_output_tokens"
            case requiresVision = "requires_vision"
            case routeMode = "route_mode"
            case deadline, body
        }
    }

    public static func decode(_ plaintext: Data) throws -> PrivateV2InnerRequest {
        guard let bodyRange = JSONRawValueExtractor.rawValueRange(forKey: "body", in: plaintext) else {
            throw PrivateV2Error.invalidInnerRequest
        }
        let rawBody = plaintext.subdata(in: bodyRange)
        var metadataOnly = plaintext
        metadataOnly.replaceSubrange(bodyRange, with: Data("null".utf8))
        let metadata: Metadata
        do { metadata = try JSONDecoder().decode(Metadata.self, from: metadataOnly) }
        catch { throw PrivateV2Error.invalidInnerRequest }
        return PrivateV2InnerRequest(
            transcript: PrivateV2Transcript(
                leaseId: metadata.leaseId,
                requestId: metadata.requestId,
                routeId: metadata.routeId,
                endpoint: metadata.endpoint,
                model: metadata.model,
                processCertificateDigest: metadata.processCertificateDigest,
                releaseBinaryHash: metadata.releaseBinaryHash,
                modelManifestHash: metadata.modelManifestHash,
                releaseGeneration: metadata.releaseGeneration,
                modelGeneration: metadata.modelGeneration,
                ownerBinding: metadata.ownerBinding,
                requestedMaxOutputTokens: metadata.requestedMaxOutputTokens,
                requiresVision: metadata.requiresVision,
                routeMode: metadata.routeMode,
                deadline: metadata.deadline),
            body: rawBody)
    }
}


public enum PrivateV2IdentityValidator {
    public static func validate(
        inner: PrivateV2InnerRequest,
        outer: PrivateV2Request,
        currentReleaseBinaryHash: String,
        currentReleaseGeneration: UInt64,
        currentModelManifestHash: String,
        currentModelGeneration: UInt64
    ) throws {
        guard inner.transcript == PrivateV2Transcript(request: outer) else {
            throw PrivateV2Error.requestMismatch
        }
        guard PrivateV2Crypto.constantTimeEqual(
            Data(outer.releaseBinaryHash.utf8),
            Data(currentReleaseBinaryHash.utf8))
        else { throw PrivateV2Error.releaseMismatch }
        guard outer.releaseGeneration == currentReleaseGeneration else {
            throw PrivateV2Error.releaseMismatch
        }
        guard outer.modelGeneration == currentModelGeneration else {
            throw PrivateV2Error.modelMismatch
        }
        guard PrivateV2Crypto.constantTimeEqual(
            Data(outer.modelManifestHash.utf8),
            Data(currentModelManifestHash.utf8))
        else { throw PrivateV2Error.modelMismatch }
    }
}

public final class PrivateV2ChunkWriter: @unchecked Sendable {
    public typealias Sink = @Sendable (PrivateV2Chunk) -> Void
    public typealias NonceGenerator = @Sendable () throws -> Data

    private let lock = NSLock()
    private let requestId: String
    private let transcriptDigest: Data
    private let sink: Sink
    private let nonceGenerator: NonceGenerator
    private var responseKey: SymmetricKey?
    private var nextSequence: UInt64 = 0
    private var terminalSent = false
    private var usedNonces = Set<Data>()

    public init(
        requestId: String,
        transcriptDigest: Data,
        responseKey: SymmetricKey,
        initialSequence: UInt64 = 0,
        nonceGenerator: @escaping NonceGenerator = PrivateV2Crypto.randomNonce,
        sink: @escaping Sink
    ) {
        self.requestId = requestId
        self.transcriptDigest = transcriptDigest
        self.responseKey = responseKey
        self.nextSequence = initialSequence
        self.nonceGenerator = nonceGenerator
        self.sink = sink
    }

    @discardableResult
    public func emit(
        payload: Data,
        terminal: Bool,
        usage: PrivateV2Usage? = nil,
        failureCode: String? = nil,
        statusCode: Int? = nil
    ) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard !terminalSent, let responseKey else { throw PrivateV2Error.terminalAlreadySent }
        let sequence = nextSequence
        guard sequence < PrivateV2Protocol.maximumChunksPerRequest,
              terminal || sequence < PrivateV2Protocol.maximumChunksPerRequest - 1
        else { throw PrivateV2Error.encryptionFailed }
        var nonce: Data?
        for _ in 0..<32 {
            let candidate = try nonceGenerator()
            guard candidate.count == 12 else { throw PrivateV2Error.invalidLength }
            if usedNonces.insert(candidate).inserted {
                nonce = candidate
                break
            }
        }
        guard let nonce else { throw PrivateV2Error.encryptionFailed }
        let plaintext = try responsePlaintext(
            sequence: sequence, terminal: terminal, payload: payload)
        let aad = try PrivateV2Crypto.responseAAD(
            transcriptDigest: transcriptDigest, sequence: sequence)
        let ciphertext = try PrivateV2Crypto.seal(
            plaintext, key: responseKey, nonce: nonce, aad: aad)
        nextSequence &+= 1
        if terminal {
            terminalSent = true
            self.responseKey = nil
        }
        sink(PrivateV2Chunk(
            requestId: requestId,
            sequence: sequence,
            terminal: terminal,
            nonce: Base64URL.encode(nonce),
            ciphertext: Base64URL.encode(ciphertext),
            usage: usage,
            failureCode: failureCode,
            statusCode: statusCode))
        return sequence
    }

    public func finish() {
        lock.lock()
        responseKey = nil
        usedNonces.removeAll(keepingCapacity: false)
        terminalSent = true
        lock.unlock()
    }

    private func responsePlaintext(sequence: UInt64, terminal: Bool, payload: Data) throws -> Data {
        guard (try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])) != nil else {
            throw PrivateV2Error.invalidBody
        }
        var data = Data("{\"payload\":".utf8)
        data.append(payload)
        data.append(Data(",\"request_id\":".utf8))
        data.append(jsonString(requestId))
        data.append(Data(",\"sequence\":\(sequence),\"terminal\":\(terminal ? "true" : "false"),\"version\":\"private_v2\"}".utf8))
        return data
    }

    private func jsonString(_ value: String) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
    }
}

public enum PrivateV2Date {
    public static func parse(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? whole.date(from: value) else {
            throw PrivateV2Error.invalidDeadline
        }
        return date
    }
}

public enum PrivateV2EndpointAdapter {
    /// Validates endpoint/model/stream binding, then maps supported public endpoint
    /// bodies into the existing chat-completions inference engine input.
    public static func chatRequestBody(
        endpoint: PrivateV2Endpoint,
        model: String,
        stream: Bool,
        requestedMaxOutputTokens: UInt64,
        defaultMaxOutputTokens: UInt64,
        requiresVision: Bool,
        body: Data
    ) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              root["model"] as? String == model
        else { throw PrivateV2Error.invalidBody }
        let bodyStream = root["stream"] as? Bool ?? false
        guard bodyStream == stream else { throw PrivateV2Error.requestMismatch }
        let maxKey = endpoint == .responses ? "max_output_tokens" : "max_tokens"
        let effectiveMax: UInt64
        if let number = root[maxKey] as? NSNumber {
            let value = number.doubleValue
            guard value >= 1, value.rounded(.towardZero) == value,
                  value <= Double(UInt64.max)
            else { throw PrivateV2Error.invalidBody }
            effectiveMax = number.uint64Value
        } else {
            effectiveMax = defaultMaxOutputTokens
        }
        guard requestedMaxOutputTokens > 0,
              requestedMaxOutputTokens <= PrivateV2Protocol.maximumOutputTokens,
              effectiveMax <= requestedMaxOutputTokens,
              containsVisionMedia(root) == requiresVision
        else { throw PrivateV2Error.requestMismatch }
        switch endpoint {
        case .chatCompletions:
            break
        case .completions:
            let prompt: String
            if let value = root["prompt"] as? String {
                prompt = value
            } else if let values = root["prompt"] as? [String], values.count == 1 {
                prompt = values[0]
            } else {
                throw PrivateV2Error.invalidBody
            }
            root["messages"] = [["role": "user", "content": prompt]]
            root.removeValue(forKey: "prompt")
        case .responses:
            guard let input = root.removeValue(forKey: "input") else {
                throw PrivateV2Error.invalidBody
            }
            root["messages"] = try lowerResponsesInput(input)
            if let max = root.removeValue(forKey: "max_output_tokens") {
                root["max_tokens"] = max
            }
            if let text = root.removeValue(forKey: "text") as? [String: Any],
               let format = text["format"] as? [String: Any] {
                if format["type"] as? String == "json_schema" {
                    var schema: [String: Any] = [:]
                    for key in ["name", "schema", "strict", "description"] {
                        if let value = format[key] { schema[key] = value }
                    }
                    root["response_format"] = [
                        "type": "json_schema", "json_schema": schema,
                    ]
                } else {
                    root["response_format"] = format
                }
            }
            if let tools = root["tools"] as? [[String: Any]] {
                root["tools"] = try tools.map(lowerResponsesTool)
            }
        case .messages:
            guard let nativeMessages = root["messages"] as? [[String: Any]] else {
                throw PrivateV2Error.invalidBody
            }
            var messages = try lowerAnthropicMessages(nativeMessages)
            let systemValue = root.removeValue(forKey: "system")
            let system: String?
            if let value = systemValue as? String {
                system = value
            } else if let blocks = systemValue as? [[String: Any]] {
                system = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                system = nil
            }
            if let system, !system.isEmpty {
                messages.insert(["role": "system", "content": system], at: 0)
            }
            root["messages"] = messages
            if let stops = root.removeValue(forKey: "stop_sequences") {
                root["stop"] = stops
            }
            if let tools = root["tools"] as? [[String: Any]] {
                root["tools"] = tools.map(lowerAnthropicTool)
            }
            if let choice = root["tool_choice"] as? [String: Any] {
                root["tool_choice"] = lowerAnthropicToolChoice(choice)
                if choice["disable_parallel_tool_use"] as? Bool == true {
                    root["parallel_tool_calls"] = false
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func lowerResponsesInput(_ input: Any) throws -> [[String: Any]] {
        if let text = input as? String {
            return [["role": "user", "content": text]]
        }
        guard let items = input as? [[String: Any]] else {
            throw PrivateV2Error.invalidBody
        }
        var messages: [[String: Any]] = []
        var pendingToolCalls: [[String: Any]] = []
        func flushToolCalls() {
            guard !pendingToolCalls.isEmpty else { return }
            messages.append([
                "role": "assistant", "content": NSNull(),
                "tool_calls": pendingToolCalls,
            ])
            pendingToolCalls.removeAll(keepingCapacity: true)
        }
        for item in items {
            let type = item["type"] as? String
            if type == "reasoning" {
                continue
            }
            if type == "function_call" {
                guard let id = item["call_id"] as? String,
                      let name = item["name"] as? String
                else { throw PrivateV2Error.invalidBody }
                pendingToolCalls.append([
                    "id": id, "type": "function",
                    "function": [
                        "name": name,
                        "arguments": jsonArgumentString(item["arguments"]),
                    ],
                ])
                continue
            }
            flushToolCalls()
            if type == "function_call_output" {
                guard let id = item["call_id"] as? String else {
                    throw PrivateV2Error.invalidBody
                }
                messages.append([
                    "role": "tool", "tool_call_id": id,
                    "content": item["output"] ?? "",
                ])
            } else if let role = item["role"] as? String {
                var message = item
                message["role"] = role
                if var content = message["content"] as? [[String: Any]] {
                    for index in content.indices {
                        if content[index]["type"] as? String == "input_text" {
                            content[index]["type"] = "text"
                        } else if content[index]["type"] as? String == "input_image" {
                            content[index]["type"] = "image_url"
                            if let url = content[index].removeValue(forKey: "image_url")
                                ?? content[index].removeValue(forKey: "url") {
                                content[index]["image_url"] = ["url": url]
                            }
                        }
                    }
                    message["content"] = content
                }
                messages.append(message)
            } else {
                throw PrivateV2Error.invalidBody
            }
        }
        flushToolCalls()
        return messages
    }

    private static func lowerResponsesTool(
        _ tool: [String: Any]
    ) throws -> [String: Any] {
        guard tool["type"] as? String == "function" else {
            throw PrivateV2Error.invalidBody
        }
        var function: [String: Any] = [:]
        for key in ["name", "description", "parameters"] {
            if let value = tool[key] { function[key] = value }
        }
        return ["type": "function", "function": function]
    }

    private static func lowerAnthropicMessages(
        _ native: [[String: Any]]
    ) throws -> [[String: Any]] {
        var output: [[String: Any]] = []
        for message in native {
            guard let role = message["role"] as? String else {
                throw PrivateV2Error.invalidBody
            }
            if let text = message["content"] as? String {
                output.append(["role": role, "content": text])
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else {
                throw PrivateV2Error.invalidBody
            }
            var contentParts: [Any] = []
            var toolCalls: [[String: Any]] = []
            func flushContent() {
                guard !contentParts.isEmpty || !toolCalls.isEmpty else { return }
                var lowered: [String: Any] = [
                    "role": role,
                    "content": contentParts.isEmpty ? NSNull() : contentParts,
                ]
                if !toolCalls.isEmpty { lowered["tool_calls"] = toolCalls }
                output.append(lowered)
                contentParts.removeAll(keepingCapacity: true)
                toolCalls.removeAll(keepingCapacity: true)
            }
            for block in blocks {
                switch block["type"] as? String {
                case "text", "image_url":
                    contentParts.append(block)
                case "image":
                    guard let source = block["source"] as? [String: Any] else {
                        throw PrivateV2Error.invalidBody
                    }
                    let url: String
                    if source["type"] as? String == "base64",
                       let media = source["media_type"] as? String,
                       let data = source["data"] as? String {
                        url = "data:\(media);base64,\(data)"
                    } else if let value = source["url"] as? String {
                        url = value
                    } else {
                        throw PrivateV2Error.invalidBody
                    }
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": url],
                    ])
                case "tool_use":
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String else {
                        throw PrivateV2Error.invalidBody
                    }
                    toolCalls.append([
                        "id": id, "type": "function",
                        "function": [
                            "name": name,
                            "arguments": jsonArgumentString(block["input"]),
                        ],
                    ])
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else {
                        throw PrivateV2Error.invalidBody
                    }
                    flushContent()
                    output.append([
                        "role": "tool", "tool_call_id": id,
                        "content": block["content"] ?? "",
                    ])
                default:
                    throw PrivateV2Error.invalidBody
                }
            }
            flushContent()
        }
        return output
    }

    private static func lowerAnthropicTool(_ tool: [String: Any]) -> [String: Any] {
        var function: [String: Any] = [:]
        for key in ["name", "description"] {
            if let value = tool[key] { function[key] = value }
        }
        function["parameters"] = tool["input_schema"] ?? [:]
        return ["type": "function", "function": function]
    }

    private static func lowerAnthropicToolChoice(_ choice: [String: Any]) -> Any {
        switch choice["type"] as? String {
        case "auto": return "auto"
        case "any": return "required"
        case "none": return "none"
        case "tool":
            return [
                "type": "function",
                "function": ["name": choice["name"] ?? ""],
            ]
        default: return "auto"
        }
    }

    private static func jsonArgumentString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func containsVisionMedia(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if let type = object["type"] as? String,
               ["image", "image_url", "input_image", "video", "video_url", "input_video"]
                .contains(type) {
                return true
            }
            return object.values.contains(where: containsVisionMedia)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsVisionMedia)
        }
        return false
    }

    public static func payload(
        fromSSE frame: String,
        endpoint: PrivateV2Endpoint = .chatCompletions
    ) -> Data? {
        for line in frame.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).drop(while: { $0 == " " || $0 == "\t" })
            if raw == "[DONE]" { return nil }
            let data = Data(raw.utf8)
            guard let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { return nil }
            if endpoint == .chatCompletions { return data }
            let first = (root["choices"] as? [[String: Any]])?.first
            let delta = first?["delta"] as? [String: Any]
            let text = delta?["content"] as? String
            let finishReason = first?["finish_reason"] as? String
            switch endpoint {
            case .chatCompletions:
                return data
            case .completions:
                guard text != nil || finishReason != nil else { return nil }
                var choice: [String: Any] = [
                    "index": first?["index"] ?? 0,
                    "text": text ?? "",
                    "logprobs": first?["logprobs"] ?? NSNull(),
                    "finish_reason": finishReason ?? NSNull(),
                ]
                if let logprobs = first?["logprobs"] { choice["logprobs"] = logprobs }
                var completion: [String: Any] = [
                    "object": "text_completion", "choices": [choice],
                ]
                for key in ["id", "created", "model"] {
                    if let value = root[key] { completion[key] = value }
                }
                return try? JSONSerialization.data(
                    withJSONObject: completion, options: [.sortedKeys])
            case .responses:
                let payload: [String: Any]
                if let text {
                    payload = ["type": "response.output_text.delta", "delta": text]
                } else if let reasoning = delta?["reasoning_content"] as? String {
                    payload = [
                        "type": "response.reasoning_summary_text.delta",
                        "delta": reasoning,
                    ]
                } else if let call = (delta?["tool_calls"] as? [[String: Any]])?.first,
                          let function = call["function"] as? [String: Any] {
                    payload = [
                        "type": "response.function_call_arguments.delta",
                        "item_id": call["id"] ?? "",
                        "name": function["name"] ?? "",
                        "delta": function["arguments"] ?? "",
                    ]
                } else {
                    return nil
                }
                return try? JSONSerialization.data(
                    withJSONObject: payload, options: [.sortedKeys])
            case .messages:
                let nativeDelta: [String: Any]
                if let text {
                    nativeDelta = ["type": "text_delta", "text": text]
                } else if let reasoning = delta?["reasoning_content"] as? String {
                    nativeDelta = ["type": "thinking_delta", "thinking": reasoning]
                } else if let call = (delta?["tool_calls"] as? [[String: Any]])?.first,
                          let function = call["function"] as? [String: Any] {
                    nativeDelta = [
                        "type": "input_json_delta",
                        "partial_json": function["arguments"] ?? "",
                        "id": call["id"] ?? "",
                        "name": function["name"] ?? "",
                    ]
                } else {
                    return nil
                }
                return try? JSONSerialization.data(
                    withJSONObject: [
                        "type": "content_block_delta", "index": 0,
                        "delta": nativeDelta,
                    ],
                    options: [.sortedKeys])
            }
        }
        return nil
    }

    public static func finishReason(fromSSE frame: String) -> String? {
        for line in frame.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
            let raw = line.dropFirst(5).drop(while: { $0 == " " || $0 == "\t" })
            guard raw != "[DONE]",
                  let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
                    as? [String: Any],
                  let choice = (object["choices"] as? [[String: Any]])?.first
            else { continue }
            if let reason = choice["finish_reason"] as? String { return reason }
        }
        return nil
    }

    public static func terminalPayload(endpoint: PrivateV2Endpoint) -> Data {
        switch endpoint {
        case .chatCompletions, .completions:
            return Data("{}".utf8)
        case .responses:
            return Data("{\"response\":{},\"type\":\"response.completed\"}".utf8)
        case .messages:
            return Data("{\"type\":\"message_stop\"}".utf8)
        }
    }

    public static func errorPayload(endpoint: PrivateV2Endpoint, failureCode: String) -> Data {
        let object: [String: Any]
        if endpoint == .messages {
            object = [
                "type": "error",
                "error": ["type": failureCode, "message": "request failed"],
            ]
        } else {
            object = [
                "error": [
                    "code": failureCode, "message": "request failed",
                    "type": "invalid_request_error",
                ],
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"error\":{\"message\":\"request failed\"}}".utf8)
    }
}

public final class PrivateV2NativeStreamAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private let endpoint: PrivateV2Endpoint
    private let requestId: String
    private let model: String
    private var started = false
    private var messageBlockType: String?
    private var messageBlockKey: String?
    private var messageBlockIndex = 0
    private var responseItemType: String?
    private var responseText = ""
    private var responseReasoning = ""
    private var responseToolID = ""
    private var responseToolName = ""
    private var responseToolArguments = ""
    private var responseToolCallID = ""
    private var responseItemID = ""
    private var responseOutputIndex = -1
    private var responseEventSequence: UInt64 = 0
    private var responseCompletedItems: [[String: Any]] = []
    private var finishReason: String?

    public init(endpoint: PrivateV2Endpoint, requestId: String, model: String) {
        self.endpoint = endpoint
        self.requestId = requestId
        self.model = model
    }

    public func payloads(fromSSE frame: String) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        if let reason = PrivateV2EndpointAdapter.finishReason(fromSSE: frame) {
            finishReason = reason
        }
        let delta = PrivateV2EndpointAdapter.payload(
            fromSSE: frame, endpoint: endpoint)
        var output: [Data] = []
        if !started {
            started = true
            switch endpoint {
            case .responses:
                output.append(json([
                    "type": "response.created",
                    "response": [
                        "id": requestId, "object": "response",
                        "status": "in_progress", "model": model, "output": [],
                    ],
                ]))
                output.append(json([
                    "type": "response.in_progress",
                    "response": [
                        "id": requestId, "object": "response",
                        "status": "in_progress", "model": model, "output": [],
                    ],
                ]))
            case .messages:
                output.append(json([
                    "type": "message_start",
                    "message": [
                        "id": requestId, "type": "message", "role": "assistant",
                        "model": model, "content": [], "stop_reason": NSNull(),
                        "usage": ["input_tokens": 0, "output_tokens": 0],
                    ],
                ]))
            case .chatCompletions, .completions:
                break
            }
        }
        guard let delta else {
            return endpoint == .responses ? numberResponseEvents(output) : output
        }
        if endpoint == .responses,
           var object = try? JSONSerialization.jsonObject(with: delta) as? [String: Any],
           let type = object["type"] as? String {
            let itemType: String
            let incomingCallID = object["item_id"] as? String ?? ""
            if type.contains("function_call") {
                itemType = "function_call"
            } else if type.contains("reasoning") {
                itemType = "reasoning"
            } else {
                itemType = "message"
            }
            let itemChanged = responseItemType.map {
                $0 != itemType
                    || (itemType == "function_call"
                        && responseToolCallID != incomingCallID)
            } ?? false
            if let current = responseItemType, itemChanged {
                output.append(contentsOf: responseDonePayloads(type: current))
            }
            if responseItemType == nil {
                responseItemType = itemType
                responseOutputIndex += 1
                responseItemID = itemType == "function_call"
                    ? "function_\(requestId)_\(responseOutputIndex)"
                    : "\(itemType)_\(requestId)_\(responseOutputIndex)"
                responseText = ""
                responseReasoning = ""
                responseToolID = responseItemID
                responseToolCallID = incomingCallID
                responseToolName = object["name"] as? String ?? ""
                responseToolArguments = ""
                let item: [String: Any]
                if itemType == "function_call" {
                    item = [
                        "type": "function_call", "id": responseItemID,
                        "call_id": responseToolCallID,
                        "name": responseToolName, "arguments": "",
                        "status": "in_progress",
                    ]
                } else if itemType == "reasoning" {
                    item = [
                        "type": "reasoning", "id": responseItemID,
                        "summary": [], "status": "in_progress",
                    ]
                } else {
                    item = [
                        "type": "message", "id": responseItemID,
                        "role": "assistant", "content": [],
                        "status": "in_progress",
                    ]
                }
                output.append(json([
                    "type": "response.output_item.added",
                    "output_index": responseOutputIndex, "item": item,
                ]))
                if itemType == "message" {
                    output.append(json([
                        "type": "response.content_part.added",
                        "item_id": responseItemID,
                        "output_index": responseOutputIndex,
                        "content_index": 0,
                        "part": ["type": "output_text", "text": ""],
                    ]))
                }
                if itemType == "reasoning" {
                    output.append(json([
                        "type": "response.reasoning_summary_part.added",
                        "item_id": responseItemID,
                        "output_index": responseOutputIndex,
                        "summary_index": 0,
                        "part": ["type": "summary_text", "text": ""],
                    ]))
                }
            }
            let itemID = responseItemID
            if type == "response.output_text.delta" {
                responseText += object["delta"] as? String ?? ""
                object["content_index"] = 0
            } else if type == "response.reasoning_summary_text.delta" {
                responseReasoning += object["delta"] as? String ?? ""
                object["summary_index"] = 0
            } else if type == "response.function_call_arguments.delta" {
                responseToolName = object["name"] as? String ?? responseToolName
                responseToolArguments += object["delta"] as? String ?? ""
            }
            object["item_id"] = itemID
            object["output_index"] = responseOutputIndex
            if itemType == "function_call" {
                object["call_id"] = responseToolCallID
            }
            output.append(json(object))
            return numberResponseEvents(output)
        }
        if endpoint == .messages,
           let object = try? JSONSerialization.jsonObject(with: delta) as? [String: Any],
           let nativeDelta = object["delta"] as? [String: Any] {
            let deltaType = nativeDelta["type"] as? String ?? "text_delta"
            let blockKey = deltaType == "input_json_delta"
                ? "\(deltaType):\(nativeDelta["id"] as? String ?? "")"
                : deltaType
            if let current = messageBlockKey, current != blockKey {
                output.append(json([
                    "type": "content_block_stop", "index": messageBlockIndex,
                ]))
                messageBlockIndex += 1
                messageBlockType = nil
                messageBlockKey = nil
            }
            if messageBlockKey == nil {
                messageBlockType = deltaType
                messageBlockKey = blockKey
                let contentBlock: [String: Any]
                if deltaType == "thinking_delta" {
                    contentBlock = ["type": "thinking", "thinking": ""]
                } else if deltaType == "input_json_delta" {
                    contentBlock = [
                        "type": "tool_use",
                        "id": nativeDelta["id"] ?? "",
                        "name": nativeDelta["name"] ?? "",
                        "input": [:],
                    ]
                } else {
                    contentBlock = ["type": "text", "text": ""]
                }
                output.append(json([
                    "type": "content_block_start", "index": messageBlockIndex,
                    "content_block": contentBlock,
                ]))
            }
            var indexedObject = object
            indexedObject["index"] = messageBlockIndex
            if var cleanDelta = indexedObject["delta"] as? [String: Any],
               cleanDelta["type"] as? String == "input_json_delta" {
                cleanDelta.removeValue(forKey: "id")
                cleanDelta.removeValue(forKey: "name")
                indexedObject["delta"] = cleanDelta
            }
            output.append(json(indexedObject))
            return output
        }
        output.append(delta)
        return output
    }

    public func closingPayloads(
        usage: PrivateV2Usage,
        stopSequence: String? = nil
    ) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        if endpoint == .responses {
            return numberResponseEvents(
                responseItemType.map(responseDonePayloads) ?? [])
        }
        guard endpoint == .messages else { return [] }
        var payloads: [Data] = []
        if messageBlockType != nil {
            payloads.append(json([
                "type": "content_block_stop", "index": messageBlockIndex,
            ]))
        }
        let stopReason: String
        if stopSequence != nil {
            stopReason = "stop_sequence"
        } else {
            switch finishReason {
            case "length": stopReason = "max_tokens"
            case "tool_calls": stopReason = "tool_use"
            case "stop", .none: stopReason = "end_turn"
            case .some(let value): stopReason = value
            }
        }
        payloads.append(json([
            "type": "message_delta",
            "delta": [
                "stop_reason": stopReason,
                "stop_sequence": stopSequence as Any? ?? NSNull(),
            ],
            "usage": ["output_tokens": usage.completionTokens],
        ]))
        return payloads
    }

    public func terminalPayload(usage: PrivateV2Usage) -> Data {
        switch endpoint {
        case .chatCompletions, .completions:
            return Data("{}".utf8)
        case .messages:
            return json(["type": "message_stop"])
        case .responses:
            var output = responseCompletedItems
            if let type = responseItemType {
                output.append(currentResponseItem(type: type))
            }
            let incomplete = finishReason == "length"
            var response: [String: Any] = [
                "id": requestId, "object": "response",
                "status": incomplete ? "incomplete" : "completed",
                "model": model, "output": output,
                "usage": [
                    "input_tokens": usage.promptTokens,
                    "output_tokens": usage.completionTokens,
                    "total_tokens": usage.totalTokens,
                ],
            ]
            if incomplete {
                response["incomplete_details"] = ["reason": "max_output_tokens"]
            }
            return responseEventJSON([
                "type": incomplete ? "response.incomplete" : "response.completed",
                "response": response,
            ])
        }
    }

    private func responseDonePayloads(type: String) -> [Data] {
        let item = currentResponseItem(type: type)
        responseCompletedItems.append(item)
        responseItemType = nil
        if type == "message" {
            let part: [String: Any] = [
                "type": "output_text", "text": responseText, "annotations": [],
            ]
            return [
                json([
                    "type": "response.output_text.done",
                    "item_id": responseItemID,
                    "output_index": responseOutputIndex,
                    "content_index": 0, "text": responseText,
                ]),
                json([
                    "type": "response.content_part.done",
                    "item_id": responseItemID,
                    "output_index": responseOutputIndex,
                    "content_index": 0, "part": part,
                ]),
                json([
                    "type": "response.output_item.done",
                    "output_index": responseOutputIndex, "item": item,
                ]),
            ]
        }
        if type == "reasoning" {
            let part: [String: Any] = [
                "type": "summary_text", "text": responseReasoning,
            ]
            return [
                json([
                    "type": "response.reasoning_summary_text.done",
                    "item_id": responseItemID,
                    "output_index": responseOutputIndex,
                    "summary_index": 0, "text": responseReasoning,
                ]),
                json([
                    "type": "response.reasoning_summary_part.done",
                    "item_id": responseItemID,
                    "output_index": responseOutputIndex,
                    "summary_index": 0, "part": part,
                ]),
                json([
                    "type": "response.output_item.done",
                    "output_index": responseOutputIndex, "item": item,
                ]),
            ]
        }
        return [
            json([
                "type": "response.function_call_arguments.done",
                "item_id": responseItemID,
                "call_id": responseToolCallID,
                "output_index": responseOutputIndex,
                "arguments": responseToolArguments,
            ]),
            json([
                "type": "response.output_item.done",
                "output_index": responseOutputIndex, "item": item,
            ]),
        ]
    }
    private func numberResponseEvents(_ events: [Data]) -> [Data] {
        events.map { data in
            guard var object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { return data }
            object["sequence_number"] = responseEventSequence
            responseEventSequence &+= 1
            return json(object)
        }
    }

    private func responseEventJSON(_ object: [String: Any]) -> Data {
        var numbered = object
        numbered["sequence_number"] = responseEventSequence
        responseEventSequence &+= 1
        return json(numbered)
    }


    private func currentResponseItem(type: String) -> [String: Any] {
        if type == "message" {
            return [
                "type": "message", "id": responseItemID,
                "role": "assistant", "status": "completed",
                "content": [[
                    "type": "output_text", "text": responseText,
                    "annotations": [],
                ]],
            ]
        }
        if type == "reasoning" {
            return [
                "type": "reasoning", "id": responseItemID,
                "status": "completed",
                "summary": [[
                    "type": "summary_text", "text": responseReasoning,
                ]],
            ]
        }
        return [
            "type": "function_call", "id": responseToolID,
            "call_id": responseToolCallID,
            "name": responseToolName, "arguments": responseToolArguments,
            "status": "completed",
        ]
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }
}
