// Copyright © 2026 Eigen Labs.

import Crypto
import Foundation

enum Gemma4ToolConstraintContract {
    static let pinnedTemplateSHA256 =
        "94899c0f917d93f6fe81c95744d1e8ddab2d21d39228d2e4aec1fb2a25bff413"

    private static let modelTypes: Set<String> = [
        "gemma4",
        "gemma4_text",
        "gemma4_vision",
    ]

    static func supports(modelType: String?) -> Bool {
        guard let modelType else { return false }
        return modelTypes.contains(modelType.lowercased())
    }

    static func templateSHA256(at modelDirectory: URL) -> String? {
        let template = modelDirectory.appendingPathComponent("chat_template.jinja")
        guard let data = try? Data(contentsOf: template, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isVerified(
        modelType: String?,
        modelDirectory: URL
    ) -> Bool {
        supports(modelType: modelType)
            && templateSHA256(at: modelDirectory) == pinnedTemplateSHA256
    }
}
