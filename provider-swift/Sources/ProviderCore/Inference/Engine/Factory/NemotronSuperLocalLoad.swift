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
    /// owner shares and KV floor).
    struct FitAttempt: Equatable, Sendable {
        let requests: Int
        let prefixBankBytes: Int
        let claimBytes: UInt64
        let admitted: Bool
        /// Its prompt chunk (`NemotronSuperLoadFit.narrowestChunkTokens` on the last).
        var chunkTokens = NemotronSuperLocalPrefill.defaultChunkTokens
    }

    private(set) var phase: Phase = .idle
    /// Every configuration the load asked the gate for, in order; the last
    /// one is the served configuration when the load was admitted.
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
    /// When the gate refuses a managed claim, the load first tries
    /// `NemotronSuperLoadFit`'s narrower configurations (no prefix bank, then
    /// fewer concurrent requests) and builds the first admitted one;
    /// `fitAttempts` records each.
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
            // Refused before the claim and installation; the builder reads it again.
            _ = try NemotronSuperVideoFeatures.validatedPruningRate(environment: environment)
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
            var admitted: (environment: [String: String], shares: NemotronSuperLocalBridgeBuilder.OwnerShares?,
                           ownerBytes: Int, kvFloor: Int, claim: PendingModelLoadLease)?
            for candidate in try NemotronSuperLoadFit.candidates(environment: environment,
                admissionKVBytes: admissionKVBytes, kvBytesCapacity: kvBytesCapacity,
                speculates: speculation != nil, contextTokens: sizing.maxContextLength) {
                let shares = staging.pinned
                    ? try NemotronSuperLocalBridgeBuilder.pinnedOwnerShares(environment: candidate.environment,
                        kvBytesCapacity: kvBytesCapacity, speculates: speculation != nil,
                        contextTokens: sizing.maxContextLength, physicalBytes: physicalBytes)
                    : nil
                guard let ownerBytes = shares.map({ $0.total }) ?? 0 else { throw Failure.capacity }
                // The bank and the round are part of the admission; the claim
                // holds each once, as a share.
                let kvFloor = candidate.admissionKVBytes - (shares?.bank ?? 0) - (shares?.round ?? 0)
                let installBytes = try NemotronSuperLoadClaim.bytes(installation: installation, head: headQuote,
                    sequential: sequential, servingBytes: max(0, ownerBytes + kvFloor))
                let (claimBytes, ownerOverflow) = installBytes.addingReportingOverflow(ownerBytes)
                let (chargedBytes, chargeOverflow) = claimBytes.addingReportingOverflow(max(0, kvFloor))
                // The gate is asked for the slack too; it is released with the
                // installation's share (pinned) or when the load finishes.
                let (askedBytes, slackOverflow) = claimBytes.addingReportingOverflow(
                    NemotronSuperLoadFit.admissionSlackBytes)
                guard !ownerOverflow, !chargeOverflow, !slackOverflow,
                    kvFloor >= Int(UnifiedMemoryCap.minimumLoadKVBytes),
                    kvBytesCapacity >= Int(UnifiedMemoryCap.minimumLoadKVBytes)
                else { continue }
                let charged = UInt64(chargedBytes)
                // A candidate the gate already weighed (no bank to drop) is not asked again.
                guard !fitAttempts.contains(where: { $0.requests == candidate.requests && $0.claimBytes == charged })
                else { continue }
                let claim = await budget.claimPendingLoad(requestID: UUID().uuidString,
                    weightBytes: UInt64(askedBytes), minimumKVBytes: UInt64(kvFloor),
                    systemReserveBytes: NemotronSuperLoadFit.systemReserveBytes)
                let chunk = NemotronSuperLocalPrefill.requestedChunkTokens(environment: candidate.environment) ?? 0
                fitAttempts.append(FitAttempt(requests: candidate.requests, prefixBankBytes: shares?.bank ?? 0,
                    claimBytes: charged, admitted: claim != nil, chunkTokens: chunk))
                guard let claim else { continue }
                admitted = (candidate.environment, shares, ownerBytes, kvFloor, claim)
                break
            }
            guard let admitted else { throw Failure.capacity }
            let (servedEnvironment, shares, ownerBytes, kvFloor, claim) = admitted
            lease = claim
            try Task.checkCancellation()
            let ledger = try NemotronSuperResidency(capacityBytes: quote, maximumRequests: 1)
            residency = ledger
            let candidate = try staging.install(ledger, backendAllowanceBytes, construction)
            installed = candidate
            try Task.checkCancellation()
            // The claim holds one transient, in the serving room: each phase's
            // freed buffers must leave MLX's cache before the next phase or
            // serving uses that room.
            guard !sequential || NemotronSuperLoadClaim.returnCachedLoadBuffers(budget: budget)
            else { throw Failure.capacity }
            var head: NemotronSuperLocalMTP.Head?
            if let speculation, let headQuote, let loader = staging.head {
                head = .init(module: try loader.load(candidate, headQuote, construction), setting: speculation)
                guard !sequential || NemotronSuperLoadClaim.returnCachedLoadBuffers(budget: budget)
                else { throw Failure.capacity }
            }
            try Task.checkCancellation()
            // The installation and any head are resident and counted as MLX
            // usage now: as the ordinary managed load does, hand their share of
            // the claim over to that live view, keeping the owner shares and the
            // KV floor until the builder takes them.
            if shares != nil {
                guard await budget.reducePendingLoad(claim, remainingWeightBytes: UInt64(ownerBytes))
                else { throw Failure.capacity }
            }
            let built = try await NemotronSuperLocalBridgeBuilder.make(installed: candidate,
                tokenizer: tokenizer, eosTokenIDs: eosTokenIDs, sizing: sizing,
                kvBytesCapacity: kvBytesCapacity, admissionKVBytes: kvFloor, kvBudget: budget,
                loadLease: claim, construction: construction, mtp: head, modelID: modelID,
                environment: servedEnvironment, physicalBytes: physicalBytes, leaseShares: shares)
            owner = built
            try Task.checkCancellation()
            // Installation/setup has fenced. The standard ledger now sees live
            // MLX allocations; no guessed concurrent-memory delta grants credit.
            guard await budget.finishPendingLoad(claim) else { throw Failure.retirement }
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
