import CryptoKit
import Foundation
import MLXLMServer
import MLXLMCommon

/// Local onboarding contract for the exact pinned Super VL template. This does
/// not admit a model, execute media, or enforce output/tool schemas.
enum NemotronSuperPromptContract {
    static let templateSHA256 = "1369e90b19976f99ce2070eb21ade8fcb4af640f008e14e82af5c5e89a9cc816"

    enum Failure: Error { case templateMismatch, unsupportedControl, conflictingControls, unsupportedMedia }

    static func verifiedTemplate(_ bytes: Data) throws -> String {
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == templateSHA256,
              let source = String(data: bytes, encoding: .utf8) else { throw Failure.templateMismatch }
        return source
    }

    private struct Controls: Decodable {
        let enabled: Bool?
        let medium: Bool?
        let truncate: Bool?
        let effort: String?
        let nestedEnabled: Bool?
        let nestedEffort: String?
        enum Keys: String, CodingKey {
            case enabled = "enable_thinking", medium = "medium_effort"
            case truncate = "truncate_history_thinking", effort = "reasoning_effort"
            case kwargs = "chat_template_kwargs", reasoning, preserve = "preserve_thinking"
        }
        enum ReasoningKeys: String, CodingKey { case enabled, effort }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            let kwargs = try values.nestedOptionalContainer(keyedBy: Keys.self, forKey: .kwargs)
            func boolean(_ key: Keys) throws -> Bool? {
                let top = try values.decodeIfPresent(Bool.self, forKey: key)
                let alias = try kwargs?.decodeIfPresent(Bool.self, forKey: key)
                if let top, let alias, top != alias { throw Failure.conflictingControls }
                return top ?? alias
            }
            enabled = try boolean(.enabled)
            medium = try boolean(.medium)
            truncate = try boolean(.truncate)
            // This generic alias has different semantics; do not silently lose it.
            guard !values.contains(.preserve), kwargs?.contains(.preserve) != true else { throw Failure.unsupportedControl }
            effort = try values.decodeIfPresent(String.self, forKey: .effort)
            let reasoning = try values.nestedOptionalContainer(keyedBy: ReasoningKeys.self, forKey: .reasoning)
            nestedEnabled = try reasoning?.decodeIfPresent(Bool.self, forKey: .enabled)
            nestedEffort = try reasoning?.decodeIfPresent(String.self, forKey: .effort)
        }
    }

    /// The official template defaults thinking on even for images. Medium effort
    /// is a separate template boolean, not the generic reasoning_effort key.
    static func additionalContext(body: Data) throws -> [String: any Sendable] {
        let controls = try JSONDecoder().decode(Controls.self, from: body)
        let effort = (controls.nestedEffort ?? controls.effort)?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let effort, !["none", "off", "0", "medium", "high"].contains(effort) {
            throw Failure.unsupportedControl
        }
        if let top = controls.effort, let nested = controls.nestedEffort,
            top.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                != nested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            throw Failure.conflictingControls
        }
        if let top = controls.enabled, let nested = controls.nestedEnabled, top != nested {
            throw Failure.conflictingControls
        }
        let disabled = ["none", "off", "0"].contains(effort ?? "")
        let enabled = controls.nestedEnabled ?? controls.enabled ?? !disabled
        if let explicit = controls.nestedEnabled ?? controls.enabled, effort != nil,
            explicit == disabled { throw Failure.conflictingControls }
        if let medium = controls.medium, effort == "medium" || effort == "high",
            medium != (effort == "medium") { throw Failure.conflictingControls }
        let medium = controls.medium ?? (effort == "medium")
        guard !(medium && !enabled) else { throw Failure.conflictingControls }
        return ["enable_thinking": enabled, "medium_effort": medium,
                "truncate_history_thinking": controls.truncate ?? true]
    }

    /// Text qualification entry: apply the verified literal template rather
    /// than a tokenizer's unverified default. Output constraints/media remain
    /// rejected until their native request owners are connected.
    static func tokenizeText(body: Data, templateBytes: Data,
        tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        let template = try verifiedTemplate(templateBytes)
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        guard request.model == NemotronSuperLocalBinding.modelID,
            request.tools == nil, request.toolChoice == nil,
            request.responseFormat == nil else { throw Failure.unsupportedControl }
        for message in request.messages {
            if case .parts(let parts) = message.content {
                for part in parts {
                    guard case .text = part else { throw Failure.unsupportedMedia }
                }
            }
        }
        let tokens = try tokenizer.applyChatTemplate(messages: messages(request.messages),
            chatTemplate: template, tools: nil, additionalContext: additionalContext(body: body))
        guard !tokens.isEmpty, tokens.allSatisfy({ (0..<131072).contains($0) }),
            !tokens.contains(18) else { throw Failure.unsupportedMedia }
        return tokens
    }

    /// Keep image slots in their original positions for an admitted media owner.
    /// URLs remain opaque values; this function never fetches or decodes media.
    static func messages(_ messages: [OpenAIChatMessage]) throws -> [[String: any Sendable]] {
        try messages.map { message in
            var value = message.templateMessageDict()
            if case .parts(let parts) = message.content {
                value["content"] = try parts.map { part -> [String: any Sendable] in
                    switch part {
                    case .text(let text): return ["type": "text", "text": text]
                    case .imageURL(let uri): return ["type": "image_url", "image_url": uri]
                    case .videoURL, .inputAudio, .unsupported: throw Failure.unsupportedMedia
                    }
                }
            }
            return value
        }
    }
}

private extension KeyedDecodingContainer {
    func nestedOptionalContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey>? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try nestedContainer(keyedBy: type, forKey: key)
    }
}
