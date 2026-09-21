// Copyright © 2026 Eigen Labs.
import Foundation

/// Exact identities for the qualified Flash-Next artifact. Feed slugs and HF
/// locators are not runtime aliases; architecture/artifact checks still apply.
public enum Qwen4ModelIdentity {
    public static let registryModelID = "qwen3.8-flash-next"
    public static let legacyModelID = "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"

    public static func isQualified(_ modelID: String?) -> Bool {
        switch modelID {
        case registryModelID, legacyModelID: return true
        default: return false
        }
    }
}
