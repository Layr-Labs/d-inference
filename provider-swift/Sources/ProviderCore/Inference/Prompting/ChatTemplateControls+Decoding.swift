import Foundation
import ProviderCoreFoundation

extension ChatTemplateControls: Decodable {
    private enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case enableThinking = "enable_thinking"
        case preserveThinking = "preserve_thinking"
        case kwargs = "chat_template_kwargs"
        case promptDate = "_darkbloom_prompt_date"
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
            preserveThinking: try? values.decode(Bool.self, forKey: .preserveThinking),
            promptDate: (try? values.decode(String.self, forKey: .promptDate)).flatMap(PromptRenderDate.init))
    }
}
