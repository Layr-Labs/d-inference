// Copyright © 2026 Eigen Labs.

import Foundation

/// Exact identity shared by the owned 9B request and default cache policies.
/// Runtime capability, cache security, admission floors and MTP remain separate.
enum Bonsai9BModelPolicy {
    static let modelID = "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit"

    static let eigenModelID = "EigenLabs/Ternary-Bonsai-2-9B-MLX-2bit"

    static func matchesModelID(_ id: String?) -> Bool {
        id == modelID || id == eigenModelID
    }

    static func contextLimit(
        modelId: String?, modelType: String?, nativeContextTokens: Int
    ) -> Int? {
        guard matches(modelId: modelId, modelType: modelType),
            nativeContextTokens > 0 else { return nil }
        return nativeContextTokens
    }

    static func matches(modelId: String?, modelType: String?) -> Bool {
        matchesModelID(modelId)
            && modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "prism_hadamard_qwen35"
    }
}
