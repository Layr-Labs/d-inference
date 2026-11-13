// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// The loop guard's way out of a repeating thought.
///
/// When the guard (`GenerationLoopGuard`) finds a verbatim loop while the row
/// is inside its reasoning channel, the row is stopped as before, and the
/// request then continues from the same tokens with the family's
/// end-of-thinking marker appended, so the model writes its answer instead of
/// ending with an empty one (`LoopExitThinkingContinuation`). A loop outside
/// the reasoning channel still ends as `length`.
public struct GenerationLoopExitThinking: Sendable {
    /// Text that opens the reasoning channel in the generated stream.
    let openMarker: String
    /// Text that closes it.
    let closeMarker: String
    /// The tokens appended to end the thought: the close marker's token.
    let exitTokens: [Int]
    /// Their text, as the client's stream shows them.
    let exitText: String
    /// The prompt itself left the reasoning channel open.
    let startsInside: Bool
    /// Shared with the continuation: the row's tokens and the guard's request.
    let record: GenerationLoopExitRecord
    /// The most the answer after the thought may take, within the request's own
    /// budget: a model that wrote a loop may write a near-verbatim one next,
    /// which the guard does not see.
    var answerTokenLimit = GenerationLoopExitThinkingPolicy.answerTokenLimit
}

/// One request's generated tokens and whether its loop guard asked to end
/// the thought. Written by the bridge's pump (through the guard) and read by
/// the scheduler's continuation once the row has ended.
public final class GenerationLoopExitRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int] = []
    private var detection: GenerationLoopDetector.Detection?

    func append(_ new: [Int]) {
        guard !new.isEmpty else { return }
        lock.withLock { tokens.append(contentsOf: new) }
    }

    func requestExit(_ detection: GenerationLoopDetector.Detection) {
        lock.withLock { if self.detection == nil { self.detection = detection } }
    }

    /// The detection that ended the thought, or nil while none did.
    var requested: GenerationLoopDetector.Detection? { lock.withLock { detection } }

    /// Every token the row produced, the in-flight ones after the stop included.
    var generatedTokens: [Int] { lock.withLock { tokens } }
}

/// Which requests may end a repeating thought instead of the whole answer.
///
/// On by default for Gemma 4 only, whose thought closes with one special
/// token (`<channel|>`). The guard keeps ending every other loop as `length`:
/// a loop outside the thought, a family without a listed marker, a request
/// that asked for logprobs (the forced token has none), a pair's request.
///
/// `DARKBLOOM_LOOP_EXIT_THINKING`: unset, `1` or `on` keeps the default list;
/// `0` or `off` turns it off; any other value is the comma-separated list of
/// `model_type`s to allow, among those with a listed marker.
enum GenerationLoopExitThinkingPolicy {
    static let environmentKey = "DARKBLOOM_LOOP_EXIT_THINKING"

    struct Markers: Sendable, Equatable {
        let open: String
        let close: String
    }

    /// The families whose thought this can end, by `model_type`.
    static let markersByModelType: [String: Markers] = [
        "gemma4": .init(open: "<|channel>", close: "<channel|>"),
        "gemma4_text": .init(open: "<|channel>", close: "<channel|>"),
    ]

    static let defaultModelTypes: Set<String> = ["gemma4", "gemma4_text"]

    /// The answer's own cap. Gemma's GPQA answers after a thought are under
    /// 1,000 tokens; a Tau2 reply or call is shorter.
    static let answerTokenLimit = 8_192

    enum Setting: Sendable, Equatable {
        case off
        case modelTypes(Set<String>)
    }

    static let current = setting(environment: ProcessInfo.processInfo.environment)

    static func setting(environment: [String: String]) -> Setting {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .modelTypes(defaultModelTypes) }
        switch raw.lowercased() {
        case "1", "on", "true": return .modelTypes(defaultModelTypes)
        case "0", "off", "false": return .off
        default:
            let types = Set(raw.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return types.isEmpty ? .off : .modelTypes(types)
        }
    }

    /// The exit for one guarded request, or nil when its loops must
    /// keep ending as `length`.
    static func resolve(
        modelType: String?,
        tokenizer: any MLXLMCommon.Tokenizer,
        promptTokens: [Int],
        logprobs: Bool,
        setting: Setting = current
    ) -> GenerationLoopExitThinking? {
        guard case .modelTypes(let enabled) = setting,
              let modelType = modelType?.lowercased(), enabled.contains(modelType),
              let markers = markersByModelType[modelType], !logprobs,
              let close = tokenizer.convertTokenToId(markers.close),
              tokenizer.convertIdToToken(close) == markers.close
        else { return nil }
        let tail = tokenizer.decode(
            tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
            skipSpecialTokens: false)
        return GenerationLoopExitThinking(
            openMarker: markers.open, closeMarker: markers.close,
            exitTokens: [close], exitText: markers.close,
            startsInside: endsInside(tail, open: markers.open, close: markers.close),
            record: GenerationLoopExitRecord())
    }

    /// Whether `text` leaves the channel open: its last marker opens it.
    static func endsInside(_ text: String, open: String, close: String) -> Bool {
        guard let opened = text.range(of: open, options: .backwards) else { return false }
        guard let closed = text.range(of: close, options: .backwards) else { return true }
        return opened.lowerBound > closed.lowerBound
    }
}
