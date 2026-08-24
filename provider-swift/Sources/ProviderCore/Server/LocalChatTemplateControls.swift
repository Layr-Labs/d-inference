// Copyright © 2026 Eigen Labs.

import Foundation

/// Recovers Qwen template-only controls from local OpenAI-compatible request
/// bodies. The upstream typed request intentionally ignores these extension
/// keys, so the local HTTP path carries them alongside the decoded request.
enum LocalChatTemplateControls {
    static func single(from data: Data) -> ChatTemplateControls {
        ProviderLoop.extractChatTemplateControls(from: data)
    }

    /// Recover controls independently for each batch item. A malformed
    /// optional control in one item must not discard valid controls in another.
    static func batch(from data: Data, count: Int) -> [ChatTemplateControls] {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
            values.count == count
        else { return Array(repeating: .init(), count: count) }

        return values.map { value in
            guard JSONSerialization.isValidJSONObject(value),
                let item = try? JSONSerialization.data(withJSONObject: value)
            else { return .init() }
            return single(from: item)
        }
    }
}
