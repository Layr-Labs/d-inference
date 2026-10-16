// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Opt-in exact prefix reuse of either Super owner: the engine's
/// process-local recurrent checkpoint bank on the contiguous backend. The
/// shared resident-cache switch (`DARKBLOOM_PREFIX_CACHE_MEMORY=1`) enables it
/// and `PrefixCachePolicy.hybridConfig` sizes it from the KV grant.
/// Checkpoints sit only at multiples of the owner's fixed prefill chunk, where
/// a restore continues a cold prefill bit for bit. On the speculating owner a
/// text checkpoint also holds the assistant's queued prompt history, from which
/// a restored request builds the same draft history as a cold one. An image
/// request reuses only checkpoints of its own image identity
/// (`NemotronSuperLocalImageBinding`); the bank holds no disk state.
enum NemotronSuperLocalPrefixCache {
    enum Failure: Error, Equatable {
        /// The bank was configured but the loaded engine did not construct it.
        case unavailable
        /// The shared budget cannot hold the bank; nothing was admitted.
        case bankRefused
    }

    /// The owner's prompt contract: its pinned literal template, which the
    /// HTTP hook verifies. A bank belongs to one loaded owner and tokenizer.
    static let promptContractID = "nemotron-super-template-" + NemotronSuperPromptContract.templateSHA256

    /// nil leaves the owner without a bank. The same bank serves both owners:
    /// the speculating owner's `NemotronSuperMTPAssistant` checkpoints its
    /// prompt history, so `hybridConfig`'s drafter gate stays off
    /// (`hasMTPDrafter: false`) for both.
    static func config(environment: [String: String], kvBytesCapacity: Int,
                       modelID: String = NemotronSuperLocalBinding.modelID)
        -> CBv2HybridPrefixCacheConfig? {
        PrefixCachePolicy.hybridConfig(modelId: modelID,
            promptContractID: promptContractID, kvBytesCapacity: kvBytesCapacity,
            hasMTPDrafter: false, environment: environment)
    }

    private static let bankSuffix = "-nemotron-super-prefix-bank"

    /// Budget reservation ID of an owner's bank, distinct from request and lane IDs.
    static func bankReservationID() -> String { UUID().uuidString + bankSuffix }

    /// True for a reservation ID made by `bankReservationID()`.
    static func isBankReservationID(_ id: String) -> Bool { id.hasSuffix(bankSuffix) }
}
