// Copyright © 2026 Eigen Labs.

import Foundation

/// The configurations a managed Super load tries, in order, under the real
/// LOAD gate (`GlobalKVCacheBudget.claimPendingLoad`).
///
/// The pinned owner's default (eight speculating requests and a prefix bank)
/// claims about 99 GiB, so with the admission slack and the provider's load
/// and activation reserves it needs about 117 GiB available: a 128 GB Mac
/// running anything else rarely has it. Before refusing, the load drops the
/// optional prefix bank, then halves the concurrent requests down to one,
/// and serves the first configuration the gate admits (one request at the
/// full context claims about 84 GiB). Every measured bound stays: the
/// installation, the head, the prefill lane, each request's fixed bytes, the
/// round at the slot's whole context and the load reserve. The bridge
/// reports the width it was built with, so the coordinator routes no more
/// concurrent work to a narrower owner.
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

    struct Candidate: Equatable, Sendable {
        /// Runtime policy the builder receives for this configuration.
        let environment: [String: String]
        /// KV headroom its LOAD claim holds, the prefix bank included.
        let admissionKVBytes: Int
        let requests: Int
    }

    /// The configured candidate, then, for a managed claim (`admissionKVBytes`
    /// non-nil), the same policy without a prefix bank at the configured
    /// width and at each halved width down to one. A whole-grant claim (the
    /// qualification runner's explicit contract) keeps only its own.
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
        return [base] + widths.map { requests in
            var reduced = withoutBank
            reduced[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] = String(requests)
            let admission = min(kvBytesCapacity, NemotronSuperServingPolicy.admissionKVBytes(
                requests: requests, speculates: speculates, environment: reduced, contextTokens: contextTokens))
            return Candidate(environment: reduced, admissionKVBytes: admission, requests: requests)
        }
    }
}
