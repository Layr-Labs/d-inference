import Foundation
import Dispatch
public struct ChatTemplateControls: Sendable, Equatable {
    public let reasoningEffort: String?
    public let enableThinking: Bool?
    public let preserveThinking: Bool?

    public init(
        reasoningEffort: String? = nil,
        enableThinking: Bool? = nil,
        preserveThinking: Bool? = nil
    ) {
        self.reasoningEffort = reasoningEffort
        self.enableThinking = enableThinking
        self.preserveThinking = preserveThinking
    }

    var effortDisablesThinking: Bool {
        guard let value = reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return ["none", "off", "0"].contains(value)
    }

    var hasExplicitThinkingControl: Bool {
        enableThinking != nil || reasoningEffort != nil
    }
}


import Foundation

extension ChatTemplateControls: Decodable {
    private enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case enableThinking = "enable_thinking"
        case preserveThinking = "preserve_thinking"
        case kwargs = "chat_template_kwargs"
    }

    /// Decode each optional extension independently: malformed values are
    /// ignored without losing valid siblings. The top-level thinking flag wins
    /// over its kwargs alias; nested `reasoning.enabled` is applied later.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let effort = (try? values.decode(String.self, forKey: .reasoningEffort))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let topLevel = try? values.decode(Bool.self, forKey: .enableThinking)
        let kwargs = try? values.nestedContainer(keyedBy: CodingKeys.self, forKey: .kwargs)
        let alias = try? kwargs?.decode(Bool.self, forKey: .enableThinking)
        self.init(
            reasoningEffort: effort?.isEmpty == false ? effort : nil,
            enableThinking: topLevel ?? alias,
            preserveThinking: try? values.decode(Bool.self, forKey: .preserveThinking))
    }
}

@inline(never) func baseline(
        from data: Data
    ) -> ChatTemplateControls {
        struct EffortProbe: Decodable { let reasoning_effort: String? }
        struct ThinkingProbe: Decodable { let enable_thinking: Bool? }
        struct PreserveProbe: Decodable { let preserve_thinking: Bool? }
        struct KwargsProbe: Decodable {
            struct Kwargs: Decodable { let enable_thinking: Bool? }
            let chat_template_kwargs: Kwargs?
        }

        let decoder = JSONDecoder()
        let rawEffort = (try? decoder.decode(EffortProbe.self, from: data))?
            .reasoning_effort
        let effort = rawEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let topLevel = (try? decoder.decode(ThinkingProbe.self, from: data))?
            .enable_thinking
        let kwargs = (try? decoder.decode(KwargsProbe.self, from: data))?
            .chat_template_kwargs?.enable_thinking
        return ChatTemplateControls(
            reasoningEffort: effort?.isEmpty == false ? effort : nil,
            enableThinking: topLevel ?? kwargs,
            preserveThinking: (try? decoder.decode(PreserveProbe.self, from: data))?
                .preserve_thinking)
    }


@inline(never) func candidate(from data: Data) -> ChatTemplateControls {
    (try? JSONDecoder().decode(ChatTemplateControls.self, from: data)) ?? .init()
}

func measure(iterations: Int, data: Data,
    operation: (Data) -> ChatTemplateControls) -> (Double, Int) {
    var checksum = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let controls = operation(data)
        checksum += controls.reasoningEffort?.utf8.count ?? 0
        checksum += controls.enableThinking == true ? 1 : 0
        checksum += controls.preserveThinking == true ? 1 : 0
    }
    return (Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1000, checksum)
}

print("Template control extraction only, Foundation JSONDecoder, swiftc -O; no inference/GPU")
var totalChecksum = 0
for (bytes, iterations) in [(1_024, 2_000), (128 * 1_024, 200), (3 * 1_024 * 1_024, 20)] {
    let padding = String(repeating: "x", count: bytes)
    let data = Data((#"{"model":"qwen","messages":[{"role":"user","content":""#
        + padding + #""}],"reasoning_effort":" high ","enable_thinking":false,"preserve_thinking":true,"chat_template_kwargs":{"enable_thinking":true}}"#).utf8)
    precondition(baseline(from: data) == candidate(from: data))
    _ = measure(iterations: 5, data: data, operation: baseline)
    _ = measure(iterations: 5, data: data, operation: candidate)
    var before: [Double] = []
    var after: [Double] = []
    for round in 0..<7 {
        let results: [(Double, Int)]
        if round.isMultiple(of: 2) {
            results = [measure(iterations: iterations, data: data, operation: baseline),
                measure(iterations: iterations, data: data, operation: candidate)]
        } else {
            let second = measure(iterations: iterations, data: data, operation: candidate)
            let first = measure(iterations: iterations, data: data, operation: baseline)
            results = [first, second]
        }
        before.append(results[0].0)
        after.append(results[1].0)
        totalChecksum += results[0].1 + results[1].1
    }
    let old = before.sorted()[3]
    let new = after.sorted()[3]
    print(String(format: "body=%d iterations=%d rounds=7 before_us=%.3f after_us=%.3f speedup=%.3f reduction_pct=%.2f", data.count, iterations, old, new, old/new, (1-new/old)*100))
    print("before_us=\(before) after_us=\(after)")
}
print("checksum=\(totalChecksum)")
