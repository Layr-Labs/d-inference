import Foundation
import Hummingbird
import MLXLMCommon
import ProviderCoreFoundation

extension DistributedLocalServer {
    func requirePreparing(_ target: DistributedLocalServerGeneration, phase expected: DistributedLocalServerPhase) throws {
        try Task.checkCancellation()
        guard generation === target, phase == expected, teardownTask == nil else {
            throw DistributedLocalServerError.startupInterrupted
        }
    }

    func prepareGeneration(_ target: DistributedLocalServerGeneration,
                           phase expected: DistributedLocalServerPhase) async throws {
        try requirePreparing(target, phase: expected)
        let session = target.session
        guard DistributedLocalSessionBinding(session) == binding else {
            throw DistributedLocalServerError.replacementIdentityChanged
        }
        try session.validateModelInputs()
        // The handle a single-Mac slot of this model uses (Gemma's pinned
        // tool-constraint contract included), so tool_choice takes one path.
        let loaded = try await tokenizerLoader(session.model.directory)
        let tokenizer = try TokenizerHandle.pairServing(loaded.inner,
            modelType: session.model.modelType, modelDirectory: session.model.directory)
        try session.validateModelInputs()
        try requirePreparing(target, phase: expected)
        let eos = try session.model.stopTokenIDs(tokenizerEOS: tokenizer.inner.eosTokenId)
        try firstTokenBudgetPolicy?.validate(maximumPromptTokens: session.profile.maxPromptTokens)
        try await session.start()
        try requirePreparing(target, phase: expected)
        // The bridge's prefix store: receipts plus the frontiers both peers
        // report holding. Absent (no reuse advertised) when the prompt contract
        // cannot be identified; the peers still reuse and report usage.
        let contract = try? PromptContractIdentity.compute(modelDirectory: session.model.directory)
        let evidence = contract.flatMap {
            ResidentPrefixCacheEvidence(modelId: session.model.publicModelID,
                modelAggregateHash: session.expectedIdentity.artifactSHA256, promptContractID: $0)
        }
        // Per-request pair telemetry for `cluster status` (S24).
        let telemetry: DistributedPairTelemetryContext? = observability.flatMap { observability in
            session.httpObservabilityFacts.map { facts in
                DistributedPairTelemetryContext(modelID: facts.modelID, mode: facts.mode, cut: facts.cut,
                    log: observability.telemetryLog(sessionID: facts.membershipEpoch ?? UUID().uuidString.lowercased()),
                    ranks: facts.ranks)
            }
        }
        target.entry = try DistributedEngineFactory.makeRegistryEntry(
            owner: session, expectedIdentity: session.expectedIdentity,
            publicModelID: session.model.publicModelID, profile: session.profile,
            tokenizer: tokenizer, eosTokenIDs: eos, modelType: session.model.modelType,
            firstTokenBudgetPolicy: firstTokenBudgetPolicy, residentPrefixEvidence: evidence,
            modelDirectory: session.model.directory, pairTelemetry: telemetry)
    }

    func prepareAndBind(_ target: DistributedLocalServerGeneration, timeout: Duration) async throws {
        try await prepareGeneration(target, phase: .starting)
        try requirePreparing(target, phase: .starting)
        try responseRouter.publish(target.responses)
        startSessionMonitor(target)
        let application = makeApplication()
        serviceTask = Task {
            do { try await application.runService(gracefulShutdownSignals: []) }
            catch is CancellationError {} catch { self.failed = true }
            self.listenerExited()
        }
        let end = ContinuousClock.now.advanced(by: timeout)
        while phase == .starting, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        if phase == .serving { return }
        try Task.checkCancellation()
        throw phase == .starting ? DistributedLocalServerError.bindTimedOut : DistributedLocalServerError.bindFailed
    }
}
