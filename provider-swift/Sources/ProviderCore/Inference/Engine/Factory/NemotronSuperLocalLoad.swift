import CryptoKit
import Foundation
import MLXLMCommon
import MLXVLM

/// One unpublished, one-shot load transaction. The host supplies authenticated
/// tokenizer identity and a KV grant from its existing slot re-slice. No registry,
/// trust, HTTP route or production slot is created here.
actor NemotronSuperLocalLoad {
    enum Phase: Equatable { case idle, loading, ready, closing, closed, retainedFault }
    enum Failure: Error { case invalidState, identity, capacity, retirement }
    private(set) var phase: Phase = .idle
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

    func load(configData: Data, source: ModelOptCheckpointSource,
        tokenizer: TokenizerHandle, eosTokenIDs: Set<Int>, sizing: SlotSizingSnapshot,
        kvBytesCapacity: Int, backendAllowanceBytes: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> EngineV2Bridge {
        guard phase == .idle else { throw Failure.invalidState }
        phase = .loading
        do {
            let hash = SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()
            guard hash == "35189a8038d1b1f934e58cba50eb7e97b42a4da569424e35b9fd1048058bc7ea" else {
                throw Failure.identity
            }
            let configuration = try NemotronSuperImageConfiguration(data: configData)
            let quote = try NemotronSuperInstallation.requiredLoadBytes(
                source: source, backendAllowanceBytes: backendAllowanceBytes)
            guard kvBytesCapacity >= Int(UnifiedMemoryCap.minimumLoadKVBytes),
                let claim = await budget.claimPendingLoad(requestID: UUID().uuidString,
                    weightBytes: UInt64(quote), minimumKVBytes: UInt64(kvBytesCapacity))
            else { throw Failure.capacity }
            lease = claim
            try Task.checkCancellation()
            let ledger = try NemotronSuperResidency(capacityBytes: quote, maximumRequests: 1)
            residency = ledger
            let candidate = try NemotronSuperInstallation.stage(configuration: configuration,
                source: source, residency: ledger, backendAllowanceBytes: backendAllowanceBytes,
                construction: construction)
            installed = candidate
            try Task.checkCancellation()
            let built = try await NemotronSuperLocalBridgeBuilder.make(installed: candidate,
                tokenizer: tokenizer, eosTokenIDs: eosTokenIDs, sizing: sizing,
                kvBytesCapacity: kvBytesCapacity, kvBudget: budget, loadLease: claim,
                construction: construction, environment: environment)
            owner = built
            try Task.checkCancellation()
            // Installation/setup has fenced. The standard ledger now sees live
            // MLX allocations; no guessed concurrent-memory delta grants credit.
            guard await budget.finishPendingLoad(claim) else { throw Failure.retirement }
            lease = nil
            phase = .ready
            return built.bridge
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
