// Red control only: the policy surface the prompt-limit tests call, without
// the change. The setting is parsed, but no chip gets a limit and the
// LaunchAgent does not forward the key.

import Foundation

@testable import ProviderCore

extension MTPAutomaticVerificationPolicy {
    enum GemmaDraftPromptLimit: Equatable {
        case chipDefault
        case off
        case tokens(Int)

        init(_ raw: String?) {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if ["0", "off", "false", "no"].contains(value) {
                self = .off
            } else if let tokens = Int(value), tokens > 0 {
                self = .tokens(tokens)
            } else {
                self = .chipDefault
            }
        }
    }

    static let gemmaMaxDraftPromptTokensEnvironmentKey = "DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS"
    static let gemmaDraftPromptLimit = GemmaDraftPromptLimit(
        ProcessInfo.processInfo.environment[gemmaMaxDraftPromptTokensEnvironmentKey])
    static let gemmaM5UltraMaxDraftPromptTokens = 4096

    static func maxDraftPromptTokens(
        modelID: String?, chipName: String? = nil, hasBenchmarkVerificationOverride: Bool = false,
        twoDrafts: Bool? = nil, limit: GemmaDraftPromptLimit? = nil
    ) -> Int? {
        nil
    }
}
