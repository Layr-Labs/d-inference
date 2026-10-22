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
/// When that owner no longer fits once the weights are installed, the next
/// narrower configurations are asked the same way beside the installation,
/// which is kept (`Claim.installedAskedWeightBytes`).
/// Each keeps every measured bound: the installation, the head, the prefill
/// lane of its chunk, each request's fixed bytes and the round at the slot's
/// whole context. The bridge reports the width it was built with, so the
/// coordinator routes no more concurrent work to a narrower owner.
///
/// Super loads keep no OS reserve beyond `admissionSlackBytes` and the
/// activation reserve unless the operator raised `memory_reserve_gb`
/// (`systemReserveBytes`): with the provider's 10% LOAD reserve the model
/// could not load on a 128 GB Mac running anything else. The narrowest
/// configuration needs `minimumAvailableBytes` (85.6 GiB) of available memory.
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

    /// `memory_reserve_gb` of every generated provider config (`ProviderSettings`).
    static let defaultConfigReserveBytes: UInt64 = 4 << 30

    /// OS reserve a Super LOAD claim keeps beside its charge and the slack,
    /// in place of the provider's `loadReserveBytes`: not the cap's implied
    /// 10%, only an operator's `memory_reserve_gb` above its 4 GiB default,
    /// whole. Every generated config carries the default, so it is no
    /// operator choice.
    static func systemReserveBytes(configReserveBytes: UInt64) -> UInt64 {
        configReserveBytes > defaultConfigReserveBytes ? configReserveBytes : 0
    }

    /// Prompt chunk of the last configuration.
    static let narrowestChunkTokens = 1_024

    /// What the gate must admit for the pinned checkpoint's narrowest
    /// configuration (`Claim.requiredBytes`): its claim (installation and head
    /// payloads, the `narrowestChunkTokens` lane, one speculating request's
    /// admission at the whole context) and the admission slack.
    static var narrowestRequirementBytes: UInt64 {
        let lane = NemotronSuperLocalPrefill.pinnedLaneBytes(chunkTokens: narrowestChunkTokens)
        let serving = lane + NemotronSuperServingPolicy.admissionKVBytes(requests: 1, speculates: true)
        return NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: true, servingBytes: serving)
            + UInt64(serving) + UInt64(admissionSlackBytes)
    }

    /// Available memory the narrowest configuration needs: its requirement
    /// and Super's activation reserve.
    static var minimumAvailableBytes: UInt64 {
        narrowestRequirementBytes
            + UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [NemotronSuperServingPolicy.modelID])
    }

    struct Candidate: Equatable, Sendable {
        /// Runtime policy the builder receives for this configuration.
        let environment: [String: String]
        /// KV headroom its LOAD claim holds, the prefix bank and any round
        /// work included.
        let admissionKVBytes: Int
        let requests: Int
    }

    /// The configured candidate, then, for a managed claim (`admissionKVBytes`
    /// non-nil), the same policy without a prefix bank at the configured
    /// width and at each halved width down to one, and that one request with
    /// `narrowestChunkTokens` chunks when its chunk is larger. Each narrower
    /// admission clamps only the part a grant holds to the grant; the round
    /// work stays whole beside it. A whole-grant claim (the qualification
    /// runner's explicit contract) keeps only its own.
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
            let admission = NemotronSuperServingPolicy.admissionKVBytes(requests: requests,
                speculates: speculates, environment: reduced, contextTokens: contextTokens,
                kvBytesCapacity: kvBytesCapacity)
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

    /// One configuration's LOAD claim as the transaction asks the gate for
    /// it: the installation and any head (with the part of their larger
    /// transient beyond the serving room), the owner shares a pinned
    /// checkpoint's claim holds (nil for a fixture, whose shares are admitted
    /// on their own) and the KV floor, the admission less the bank and round
    /// it already contains.
    struct Claim: Equatable, Sendable {
        let shares: NemotronSuperLocalBridgeBuilder.OwnerShares?
        /// Lane, round and bank: handed to their own reservations.
        let ownerBytes: Int
        let kvFloorBytes: Int
        /// Everything the lease holds (`NemotronSuperLocalLoad.FitAttempt.claimBytes`).
        let chargedBytes: UInt64
        /// The claim's weight part (installation, head and owner shares) and
        /// `admissionSlackBytes`, asked for beside the KV floor.
        let askedWeightBytes: UInt64
        /// What the gate must admit for this configuration.
        var requiredBytes: UInt64 { askedWeightBytes + UInt64(kvFloorBytes) }
        /// `askedWeightBytes` once the installation and any head are
        /// resident and their load transients are over: live usage counts a
        /// pinned configuration's payloads, so it asks for its owner shares
        /// and the slack; a fixture's lease must still hold them
        /// (`NemotronSuperLocalBridgeBuilder.make`).
        var installedAskedWeightBytes: UInt64 {
            shares == nil ? askedWeightBytes : UInt64(ownerBytes) + UInt64(admissionSlackBytes)
        }
    }

    /// nil when the configuration cannot hold the minimum KV or its bytes
    /// overflow. `installationBytes` gives the installation's and any head's
    /// LOAD bytes beside a serving room.
    static func claim(_ candidate: Candidate, kvBytesCapacity: Int,
                      shares: NemotronSuperLocalBridgeBuilder.OwnerShares?,
                      installationBytes: (_ servingBytes: Int) throws -> Int) rethrows -> Claim? {
        let minimum = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        let kvFloor = candidate.admissionKVBytes - (shares?.bank ?? 0) - (shares?.round ?? 0)
        guard kvBytesCapacity >= minimum, kvFloor >= minimum,
            let ownerBytes = shares.map({ $0.total }) ?? 0
        else { return nil }
        let (serving, servingOverflow) = ownerBytes.addingReportingOverflow(kvFloor)
        guard !servingOverflow else { return nil }
        let (weight, weightOverflow) = try installationBytes(serving).addingReportingOverflow(ownerBytes)
        let (charged, chargeOverflow) = weight.addingReportingOverflow(kvFloor)
        let (asked, askedOverflow) = weight.addingReportingOverflow(admissionSlackBytes)
        let (_, requiredOverflow) = asked.addingReportingOverflow(kvFloor)
        guard !weightOverflow, !chargeOverflow, !askedOverflow, !requiredOverflow else { return nil }
        return Claim(shares: shares, ownerBytes: ownerBytes, kvFloorBytes: kvFloor,
                     chargedBytes: UInt64(charged), askedWeightBytes: UInt64(asked))
    }

    /// What the gate must admit (`Claim.requiredBytes`) for each of the
    /// pinned checkpoint's configurations under `plan` and its grant, in the
    /// order the load tries them, from the serving policy's recorded quotes;
    /// a configuration that cannot hold the minimum KV is left out.
    static func pinnedRequirements(plan: NemotronSuperServingPolicy.LoadPlan, kvBytesCapacity: Int,
                                   physicalBytes: UInt64) throws -> [UInt64] {
        let context = NemotronSuperServingPolicy.contextTokens
        return try candidates(environment: plan.environment, admissionKVBytes: plan.admissionKVBytes,
                              kvBytesCapacity: kvBytesCapacity, speculates: plan.speculates,
                              contextTokens: context).compactMap { candidate in
            let shares = try NemotronSuperLocalBridgeBuilder.pinnedOwnerShares(environment: candidate.environment,
                kvBytesCapacity: kvBytesCapacity, speculates: plan.speculates, contextTokens: context,
                physicalBytes: physicalBytes)
            return claim(candidate, kvBytesCapacity: kvBytesCapacity, shares: shares) {
                Int(clamping: NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: plan.speculates,
                                                                              servingBytes: $0))
            }?.requiredBytes
        }
    }
}
