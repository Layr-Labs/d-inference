// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Exact prefix reuse of either Super owner: the engine's process-local
/// recurrent checkpoint bank on the owner's paged KV (adoption writes the
/// bank's own copy of the prefix into fresh pages). The shared
/// resident-cache switch (`DARKBLOOM_PREFIX_CACHE_MEMORY=1`) enables it.
/// For the pinned checkpoint `NemotronSuperServingPolicy.defaultPrefixBankBytes`
/// sizes it from the KV grant; an operator's `DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES`
/// wins, and other checkpoints keep `PrefixCachePolicy.hybridConfig`'s default.
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
    /// (`hasMTPDrafter: false`) for both. `pinned` selects the pinned
    /// checkpoint's measured default size; `requests` and `speculates` are the
    /// owner's configuration under this grant, `physicalBytes` the machine's.
    static func config(environment: [String: String], kvBytesCapacity: Int, requests: Int,
                       speculates: Bool, pinned: Bool = true,
                       physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
                       modelID: String = NemotronSuperLocalBinding.modelID)
        -> CBv2HybridPrefixCacheConfig? {
        let defaultBytes = pinned
            ? NemotronSuperServingPolicy.defaultPrefixBankBytes(kvBytesCapacity: kvBytesCapacity,
                requests: requests, speculates: speculates, environment: environment,
                physicalBytes: physicalBytes)
            : nil
        guard var config = PrefixCachePolicy.hybridConfig(modelId: modelID,
            promptContractID: promptContractID, kvBytesCapacity: kvBytesCapacity,
            hasMTPDrafter: false, defaultBytes: defaultBytes, environment: environment)
        else { return nil }
        config.maximumEntries = max(config.maximumEntries, config.maximumBytes / entryBytesFloor)
        config.permitsPagedStorage = true
        return config
    }

    /// A Super entry holds at least one recurrent checkpoint (162 MiB of conv
    /// and SSM state on the pinned checkpoint). One entry per 256 MiB lets a
    /// large bank fill with short prompts instead of stopping at the generic
    /// 32 entries; a bank of 8 GiB or less keeps those 32.
    static let entryBytesFloor = 256 << 20

    private static let bankSuffix = "-nemotron-super-prefix-bank"

    /// Budget reservation ID of an owner's bank, distinct from request and lane IDs.
    static func bankReservationID() -> String { UUID().uuidString + bankSuffix }

    /// True for a reservation ID made by `bankReservationID()`.
    static func isBankReservationID(_ id: String) -> Bool { id.hasSuffix(bankSuffix) }
}
