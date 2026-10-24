import CryptoKit
import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// One unpublished, one-shot load transaction. The host supplies authenticated
/// tokenizer identity and a KV grant from its existing slot re-slice. No registry,
/// trust, HTTP route or production slot is created here; the provider's managed
/// load installs the returned owner as its slot.
actor NemotronSuperLocalLoad {
    enum Phase: Equatable { case idle, loading, ready, closing, closed, retainedFault }
    enum Failure: Error { case invalidState, identity, capacity, retirement }

    /// What the transaction installs. `pinned` is the only production staging:
    /// the config identity and `NemotronSuperInstallation.stage`'s index and
    /// shard pins. Fixtures stage through the same claim, fences and builder.
    struct Staging {
        let source: ModelOptCheckpointSource
        let install: (NemotronSuperResidency, Int, NativeConstructionScope) throws
            -> NemotronSuperInstallation.Installed
        /// The embedded speculation head; nil when the staging carries none.
        let head: Head?
        /// The pinned checkpoint: its LOAD claim also covers the owner's
        /// prefill lane and prefix bank (`NemotronSuperLocalBridgeBuilder.OwnerShares`).
        var pinned = false

        struct Head {
            let quote: () throws -> NemotronSuperMTPModule.LoadQuote
            let load: (NemotronSuperInstallation.Installed, NemotronSuperMTPModule.LoadQuote,
                       NativeConstructionScope) throws -> NemotronSuperMTPModule
        }

        static func pinned(configData: Data, source: ModelOptCheckpointSource) throws -> Staging {
            let hash = SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()
            guard hash == NemotronSuperServingPolicy.configSHA256 else { throw Failure.identity }
            let configuration = try NemotronSuperImageConfiguration(data: configData)
            let head = Head(quote: {
                try NemotronSuperMTPServing.loadQuote(configuration: configuration, source: source)
            }, load: { installed, quote, construction in
                try NemotronSuperMTPServing.loadHead(installed: installed, source: source, quote: quote,
                                                     construction: construction)
            })
            return Staging(source: source, install: { residency, allowance, construction in
                try NemotronSuperInstallation.stage(configuration: configuration, source: source,
                    residency: residency, backendAllowanceBytes: allowance, construction: construction)
            }, head: head, pinned: true)
        }
    }

    /// One configuration the LOAD gate weighed (`NemotronSuperLoadFit`): its
    /// concurrent requests, prefix bank and whole claim (installation, head,
    /// owner shares and KV floor), also when it was asked after installation
    /// for `NemotronSuperLoadFit.Claim.installedAskedWeightBytes` only.
    struct FitAttempt: Equatable, Sendable {
        let requests: Int
        let prefixBankBytes: Int
        let claimBytes: UInt64
        let admitted: Bool
        /// Its prompt chunk (`NemotronSuperLoadFit.narrowestChunkTokens` on the last).
        var chunkTokens = NemotronSuperLocalPrefill.defaultChunkTokens
        /// Admitted, but the builder then refused its owner beside the
        /// installed weights (`isMemoryRefusal`); any later attempt was
        /// asked beside the same installation.
        var lostAfterInstallation = false
    }

    /// A configuration the gate admitted: its runtime policy, its claim, the
    /// lease and its index in `fitAttempts`.
    private struct Admission {
        let environment: [String: String]
        let fit: NemotronSuperLoadFit.Claim
        let lease: PendingModelLoadLease
        let attempt: Int
    }

    private(set) var phase: Phase = .idle
    /// Every configuration the load asked the gate for, in order; the last
    /// one is the served configuration when the load completes.
    private(set) var fitAttempts: [FitAttempt] = []
    private let budget: GlobalKVCacheBudget
    private let construction = NativeConstructionScope()
    private var lease: PendingModelLoadLease?
    private var residency: NemotronSuperResidency?
    private var installed: NemotronSuperInstallation.Installed?
    private var owner: NemotronSuperLocalBridgeBuilder.Owner?
    // A fault must keep native owners and their charge even if the caller drops
    // its transaction handle. Deliberate process-lifetime quarantine, no refund.
    private var quarantine: NemotronSuperLocalLoad?

    init(budget: GlobalKVCacheBudget) { self.budget = budget }

    /// The pinned checkpoint. `admissionKVBytes` is the KV headroom the LOAD
    /// claim requires (nil: the whole grant, the qualification runner's
    /// contract), including any prefix bank; the grant itself is the engine's
    /// admission ceiling. One claim, taken before any allocation, covers the
    /// whole loaded owner: installation, any head, the prefill lane, the bank
    /// and the requests' KV. Once the weights are resident (MLX usage) their
    /// share is handed over to live usage, and the builder hands the lane and
    /// bank shares to their reservations, so each byte is counted once.
    /// When the gate refuses a managed claim, the load returns MLX's cached
    /// buffers once and asks again, then tries `NemotronSuperLoadFit`'s
    /// narrower configurations (no prefix bank, then fewer concurrent
    /// requests, then shorter prompt chunks) and builds the first admitted
    /// one; `fitAttempts` records each. When the builder refuses that owner
    /// for want of memory once the weights are installed, the installation
    /// and any head are kept and the narrower configurations left are asked
    /// for the rest of their claims, beside them, in the same way.
    func load(configData: Data, source: ModelOptCheckpointSource,
        tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>, sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int, admissionKVBytes: Int? = nil, backendAllowanceBytes: Int,
        modelID: String = NemotronSuperLocalBinding.modelID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) async throws -> EngineV2Bridge {
        try await load(staging: { try .pinned(configData: configData, source: source) },
            tokenizer: tokenizer, eosTokenIDs: eosTokenIDs, sizing: sizing,
            kvBytesCapacity: kvBytesCapacity, admissionKVBytes: admissionKVBytes,
            backendAllowanceBytes: backendAllowanceBytes, modelID: modelID, environment: environment,
            physicalBytes: physicalBytes)
    }

    func load(staging makeStaging: () throws -> Staging,
        tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>, sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int, admissionKVBytes: Int? = nil, backendAllowanceBytes: Int,
        modelID: String, environment: [String: String],
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) async throws -> EngineV2Bridge {
        guard phase == .idle else { throw Failure.invalidState }
        phase = .loading
        do {
            let staging = try makeStaging()
            let source = staging.source
            let installation = try NemotronSuperInstallation.loadQuote(
                source: source, backendAllowanceBytes: backendAllowanceBytes)
            let quote = installation.totalBytes
            // Refused before the claim and installation; the builder reads them again.
            _ = try NemotronSuperVideoFeatures.validatedPruningRate(environment: environment)
            _ = try NemotronSuperLocalKVBackend.resolve(environment: environment)
            // Speculation adds the embedded head's payload and loader
            // construction allowance to the same LOAD claim, before allocation.
            let speculation = try NemotronSuperLocalMTP.Setting.resolve(environment: environment)
            let headQuote = try speculation.map { _ in
                guard let head = staging.head else { throw Failure.identity }
                return try head.quote()
            }
            if let headQuote { _ = try NemotronSuperLocalMTP.loadSupplementBytes(headQuote) }
            // With reclamation the load transients are sequential and run in
            // the serving room (owner shares, the round's included, and the KV
            // floor) before any of it is allocated.
            let sequential = NemotronSuperLoadClaim.mayReturnStagingBuffers()
            // The bank and the round are part of the admission; the claim
            // holds each once, as a share. The gate is asked for the slack
            // too; it is released with the installation's share (pinned)
            // or when the load finishes.
            let claim = { (candidate: NemotronSuperLoadFit.Candidate) throws -> NemotronSuperLoadFit.Claim? in
                let shares = staging.pinned
                    ? try NemotronSuperLocalBridgeBuilder.pinnedOwnerShares(environment: candidate.environment,
                        kvBytesCapacity: kvBytesCapacity, speculates: speculation != nil,
                        contextTokens: sizing.maxContextLength, physicalBytes: physicalBytes)
                    : nil
                return try NemotronSuperLoadFit.claim(candidate, kvBytesCapacity: kvBytesCapacity,
                    shares: shares, installationBytes: {
                        try NemotronSuperLoadClaim.bytes(installation: installation, head: headQuote,
                            sequential: sequential, servingBytes: $0)
                    })
            }
            var remaining = try NemotronSuperLoadFit.candidates(environment: environment,
                admissionKVBytes: admissionKVBytes, kvBytesCapacity: kvBytesCapacity,
                speculates: speculation != nil, contextTokens: sizing.maxContextLength)[...]
            var returnedCachedBuffers = false
            guard var admitted = try await admitNext(from: &remaining, afterInstallation: false,
                returnedCachedBuffers: &returnedCachedBuffers, claim: claim)
            else { throw Failure.capacity }
            lease = admitted.lease
            try Task.checkCancellation()
            let ledger = try NemotronSuperResidency(capacityBytes: quote, maximumRequests: 1)
            residency = ledger
            let staged = try staging.install(ledger, backendAllowanceBytes, construction)
            installed = staged
            try Task.checkCancellation()
            // The claim holds one transient, in the serving room: each phase's
            // freed buffers must leave MLX's cache before the next phase or
            // serving uses that room.
            guard !sequential || NemotronSuperLoadClaim.returnCachedLoadBuffers(budget: budget)
            else { throw Failure.capacity }
            var head: NemotronSuperLocalMTP.Head?
            if let speculation, let headQuote, let loader = staging.head {
                head = .init(module: try loader.load(staged, headQuote, construction), setting: speculation)
                guard !sequential || NemotronSuperLoadClaim.returnCachedLoadBuffers(budget: budget)
                else { throw Failure.capacity }
            }
            try Task.checkCancellation()
            let built: NemotronSuperLocalBridgeBuilder.Owner
            while true {
                // The installation and any head are resident and counted as MLX
                // usage now: as the ordinary managed load does, hand their share
                // of the claim over to that live view (a claim taken after
                // installation holds none) and release the slack, keeping the
                // owner shares and the KV floor until the builder takes them.
                if admitted.fit.shares != nil {
                    guard await budget.reducePendingLoad(admitted.lease,
                        remainingWeightBytes: UInt64(admitted.fit.ownerBytes))
                    else { throw Failure.capacity }
                }
                do {
                    built = try await NemotronSuperLocalBridgeBuilder.make(installed: staged,
                        tokenizer: tokenizer, eosTokenIDs: eosTokenIDs, sizing: sizing,
                        kvBytesCapacity: kvBytesCapacity, admissionKVBytes: admitted.fit.kvFloorBytes,
                        kvBudget: budget, loadLease: admitted.lease, construction: construction, mtp: head,
                        modelID: modelID, environment: admitted.environment, physicalBytes: physicalBytes,
                        leaseShares: admitted.fit.shares)
                    break
                } catch let refusal where Self.isMemoryRefusal(refusal) {
                    // Any bridge the builder built has retired and its own
                    // reservations are released. Keep the installation and any
                    // head; finish this claim and ask for the next narrower
                    // configuration beside them, or fail with this refusal.
                    fitAttempts[admitted.attempt].lostAfterInstallation = true
                    guard await budget.finishPendingLoad(admitted.lease) else { throw refusal }
                    lease = nil
                    guard let narrower = try await admitNext(from: &remaining, afterInstallation: true,
                        returnedCachedBuffers: &returnedCachedBuffers, claim: claim)
                    else { throw refusal }
                    admitted = narrower
                    lease = narrower.lease
                    try Task.checkCancellation()
                }
            }
            owner = built
            try Task.checkCancellation()
            // Installation/setup has fenced. The standard ledger now sees live
            // MLX allocations; no guessed concurrent-memory delta grants credit.
            guard await budget.finishPendingLoad(admitted.lease) else { throw Failure.retirement }
            lease = nil
            phase = .ready
            return built.bridge
        } catch NemotronSuperLocalBridgeBuilder.Failure.retirementIncomplete {
            // A bridge that did not retire may still use the installation.
            phase = .retainedFault; quarantine = self
            throw NemotronSuperLocalBridgeBuilder.Failure.retirementIncomplete
        } catch {
            await retireFailedLoad()
            throw error
        }
    }

    /// Asks the gate for each of `candidates` in turn, consuming them, and
    /// returns the first it admits; `fitAttempts` records each with its whole
    /// claim. After installation each is asked for
    /// `NemotronSuperLoadFit.Claim.installedAskedWeightBytes` beside its KV floor.
    private func admitNext(from candidates: inout ArraySlice<NemotronSuperLoadFit.Candidate>,
        afterInstallation: Bool, returnedCachedBuffers: inout Bool,
        claim: (NemotronSuperLoadFit.Candidate) throws -> NemotronSuperLoadFit.Claim?
    ) async throws -> Admission? {
        while let candidate = candidates.popFirst() {
            guard let fit = try claim(candidate) else { continue }
            // A candidate the gate already weighed (no bank to drop) is not asked again.
            guard !fitAttempts.contains(where: {
                $0.requests == candidate.requests && $0.claimBytes == fit.chargedBytes
            }) else { continue }
            // A refusal only schedules the reclaimer's flush of MLX's
            // cache; before narrowing, return the cached buffers once and
            // ask again for the same configuration. That flush runs on its
            // own and may already be done when the cache is read after the
            // refusal, so the cache held when asking counts too.
            let cachedWhenAsked = returnedCachedBuffers ? 0 : budget.memoryHeadroomSnapshot().cacheBytes
            var granted = await pendingLoad(fit, afterInstallation: afterInstallation)
            if granted == nil, !returnedCachedBuffers,
                cachedWhenAsked > 0 || budget.memoryHeadroomSnapshot().cacheBytes > 0 {
                returnedCachedBuffers = true
                if NemotronSuperLoadClaim.returnCachedLoadBuffers(budget: budget) {
                    granted = await pendingLoad(fit, afterInstallation: afterInstallation)
                }
            }
            let chunk = NemotronSuperLocalPrefill.requestedChunkTokens(environment: candidate.environment) ?? 0
            fitAttempts.append(FitAttempt(requests: candidate.requests, prefixBankBytes: fit.shares?.bank ?? 0,
                claimBytes: fit.chargedBytes, admitted: granted != nil, chunkTokens: chunk))
            guard let granted else { continue }
            return Admission(environment: candidate.environment, fit: fit, lease: granted,
                             attempt: fitAttempts.count - 1)
        }
        return nil
    }

    /// One configuration's LOAD claim, beside Super's own system reserve.
    private func pendingLoad(_ fit: NemotronSuperLoadFit.Claim, afterInstallation: Bool) async
        -> PendingModelLoadLease? {
        await budget.claimPendingLoad(requestID: UUID().uuidString,
            weightBytes: afterInstallation ? fit.installedAskedWeightBytes : fit.askedWeightBytes,
            minimumKVBytes: UInt64(fit.kvFloorBytes),
            systemReserveBytes: NemotronSuperLoadFit.systemReserveBytes(configReserveBytes: budget.configReserveBytes))
    }

    /// The builder's refusals a narrower owner may avoid: the claim no longer
    /// covering the owner (`loadAdmissionLost`) or the shared budget refusing
    /// the lane, decode rows, round or bank (rows and round also when their
    /// bytes cannot be sized). Each is thrown with no bridge left (a built one
    /// has retired) and none of the builder's reservations held, so a
    /// narrower owner may still be built over the same installation.
    private static func isMemoryRefusal(_ error: Error) -> Bool {
        switch error {
        case NemotronSuperLocalBridgeBuilder.Failure.loadAdmissionLost,
             NemotronSuperLocalPrefill.Failure.laneRefused,
             NemotronSuperLocalKVBackend.Failure.decodeRowsRefused,
             NemotronSuperLocalMTP.Failure.roundRefused,
             NemotronSuperLocalPrefixCache.Failure.bankRefused:
            return true
        default:
            return false
        }
    }

    /// Dedicated unpublished image execution; no shared registry/native lease.
    func localImageBinding() throws -> NemotronSuperLocalImageBinding {
        guard phase == .ready, let owner else { throw Failure.invalidState }
        return try owner.localImageBinding()
    }

    func localImagePrompt(body: Data, templateBytes: Data, featureCounts: [Int]) throws -> [Int] {
        guard phase == .ready, let owner else { throw Failure.invalidState }
        return try owner.localImagePrompt(body: body, templateBytes: templateBytes,
                                         featureCounts: featureCounts)
    }

    /// The HTTP chat route over this transaction's own owner, text and images.
    /// The host drains it before `closeAfterDrain`.
    func localImageHTTP(templateBytes: Data) throws -> NemotronSuperLocalImageHTTP {
        guard phase == .ready, let owner else { throw Failure.invalidState }
        return try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: templateBytes)
    }

    /// Read-only installation residency for diagnostics, kept after close.
    var residencySnapshot: NemotronSuperResidency.Snapshot? { residency?.snapshot }

    /// The built owner's shared-budget reservations beside its KV grant and
    /// its prefix bank; zero without an owner.
    var ownerReservations: (besideGrant: Int, bank: Int) {
        (owner?.reservedBesideGrantBytes ?? 0, owner?.prefixBankBytes ?? 0)
    }

    /// Host must first close acquisition and drain all bindings. Concurrent close
    /// while loading is rejected; cancellation belongs to the load task's owner.
    func closeAfterDrain() async throws {
        guard phase == .ready else { throw Failure.invalidState }
        phase = .closing
        do {
            try await owner?.closeAfterDrain()
            owner = nil; installed = nil
            _ = residency?.beginDrain()
            phase = .closed
        } catch {
            phase = .retainedFault; quarantine = self
            throw error
        }
    }

    private func retireFailedLoad() async {
        if construction.snapshot.isRetainedFault {
            phase = .retainedFault; quarantine = self
            return
        }
        do { try await owner?.closeAfterDrain() }
        catch { phase = .retainedFault; quarantine = self; return }
        owner = nil
        installed?.closeAfterRetirement(); installed = nil
        _ = residency?.beginDrain()
        if let lease {
            guard await budget.finishPendingLoad(lease) else {
                phase = .retainedFault; quarantine = self; return
            }
        }
        lease = nil
        phase = .closed
    }
}
