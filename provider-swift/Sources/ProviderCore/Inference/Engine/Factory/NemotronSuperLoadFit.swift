// Copyright © 2026 Eigen Labs.

import Foundation

/// The configurations a managed Super load tries, in order, under the real
/// LOAD gate (`GlobalKVCacheBudget.claimPendingLoad`).
///
/// The pinned owner's default (eight speculating requests and a prefix bank)
/// claims about 99 GiB. Before refusing, the load drops the optional prefix
/// bank, then halves the concurrent requests down to one, then serves that
/// request with `narrowestChunkTokens` prompt chunks (a 4.75 GiB prefill lane
/// instead of 8.5 GiB), and builds the first configuration the gate admits.
/// Each keeps every measured bound: the installation, the head, the prefill
/// lane of its chunk, each request's fixed bytes and the round at the slot's
/// whole context. The bridge reports the width it was built with, so the
/// coordinator routes no more concurrent work to a narrower owner.
///
/// Super loads keep no OS reserve beyond `admissionSlackBytes` and the
/// activation reserve (`systemReserveBytes`): with the provider's 10% LOAD
/// reserve the model could not load on a 128 GB Mac running anything else.
/// The narrowest configuration needs `minimumAvailableBytes` (85.6 GiB) of
/// available memory.
enum NemotronSuperLoadFit {
    /// Room the gate must have beyond a configuration's claim when it is
    /// asked; `FitAttempt.claimBytes` excludes it, and the lease releases it
    /// with the installation's share. While the claim is held the process
    /// grows past the installation's quote (MLX allocations as the builder
    /// hands its shares over, and non-MLX process memory): at most 2.60 GB
    /// on the full checkpoint (four requests, a 107 GiB Mac emulated on the
    /// M3 Ultra), where 1.93 GB of room lost the admission after the
    /// installation. Without the slack such a configuration is admitted and
    /// fails only once its weights are installed; with it, the gate refuses it
    /// and the next narrower one is tried.
    static let admissionSlackBytes = 3 << 30

    /// OS reserve a Super LOAD claim keeps beside its charge and the slack, in
    /// place of the provider's `loadReserveBytes`.
    static let systemReserveBytes: UInt64 = 0

    /// Prompt chunk of the last configuration.
    static let narrowestChunkTokens = 1_024

    /// Available memory the pinned checkpoint's narrowest configuration needs:
    /// its claim (installation and head payloads, the `narrowestChunkTokens`
    /// lane, one speculating request's admission at the whole context), the
    /// admission slack and Super's activation reserve.
    static var minimumAvailableBytes: UInt64 {
        let lane = NemotronSuperLocalPrefill.pinnedLaneBytes(chunkTokens: narrowestChunkTokens)
        let serving = lane + NemotronSuperServingPolicy.admissionKVBytes(requests: 1, speculates: true)
        let claim = NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: true, servingBytes: serving)
            + UInt64(serving)
        return claim + UInt64(admissionSlackBytes)
            + UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [NemotronSuperServingPolicy.modelID])
    }

    struct Candidate: Equatable, Sendable {
        /// Runtime policy the builder receives for this configuration.
        let environment: [String: String]
        /// KV headroom its LOAD claim holds, the prefix bank included.
        let admissionKVBytes: Int
        let requests: Int
    }

    /// The configured candidate, then, for a managed claim (`admissionKVBytes`
    /// non-nil), the same policy without a prefix bank at the configured
    /// width and at each halved width down to one, and that one request with
    /// `narrowestChunkTokens` chunks when its chunk is larger. A whole-grant
    /// claim (the qualification runner's explicit contract) keeps only its own.
    static func candidates(environment: [String: String], admissionKVBytes: Int?,
                           kvBytesCapacity: Int, speculates: Bool, contextTokens: Int) throws -> [Candidate] {
        let configured = try NemotronSuperLocalBridgeBuilder.concurrentRequests(
            environment: environment, speculates: speculates)
        let base = Candidate(environment: environment, admissionKVBytes: admissionKVBytes ?? kvBytesCapacity,
                             requests: configured)
        guard admissionKVBytes != nil else { return [base] }
        var withoutBank = environment
        withoutBank[PrefixCachePolicy.memoryEnvironmentFlag] = "0"
        let widths = sequence(first: configured) { $0 > 1 ? $0 / 2 : nil }
        var result = [base] + widths.map { requests in
            var reduced = withoutBank
            reduced[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] = String(requests)
            let admission = min(kvBytesCapacity, NemotronSuperServingPolicy.admissionKVBytes(
                requests: requests, speculates: speculates, environment: reduced, contextTokens: contextTokens))
            return Candidate(environment: reduced, admissionKVBytes: admission, requests: requests)
        }
        if let last = result.last,
            let chunk = NemotronSuperLocalPrefill.requestedChunkTokens(environment: last.environment),
            chunk > narrowestChunkTokens {
            var smaller = last.environment
            smaller[NemotronSuperLocalPrefill.chunkKey] = String(narrowestChunkTokens)
            result.append(Candidate(environment: smaller, admissionKVBytes: last.admissionKVBytes, requests: 1))
        }
        return result
    }
}
