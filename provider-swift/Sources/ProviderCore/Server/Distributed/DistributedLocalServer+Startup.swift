import Foundation
import Hummingbird
import MLXLMCommon

extension DistributedLocalServer {
    func requirePreparing(_ target: DistributedLocalServerGeneration, phase expected: DistributedLocalServerPhase) throws {
        try Task.checkCancellation()
        guard generation === target, phase == expected, teardownTask == nil else {
            throw DistributedLocalServerError.startupInterrupted
        }
    }

    func prepareGeneration(_ target: DistributedLocalServerGeneration,
                           phase expected: DistributedLocalServerPhase) async throws -> UInt64 {
        try requirePreparing(target, phase: expected)
        let session = target.session
        guard DistributedLocalSessionBinding(session) == binding else {
            throw DistributedLocalServerError.replacementIdentityChanged
        }
        try session.validateModelInputs()
        let tokenizer = try await tokenizerLoader(session.model.directory)
        try session.validateModelInputs()
        try requirePreparing(target, phase: expected)
        let eos = try session.model.stopTokenIDs(tokenizerEOS: tokenizer.inner.eosTokenId)
        try firstTokenBudgetPolicy?.validate(maximumPromptTokens: session.profile.maxPromptTokens)
        try await session.start()
        try requirePreparing(target, phase: expected)
        guard let lifetime = session.lifetimeDeadlineUptimeNanoseconds,
              lifetime > DispatchTime.now().uptimeNanoseconds else {
            throw DistributedLocalServerError.lifetimeExpired
        }
        target.entry = try DistributedEngineFactory.makeRegistryEntry(
            owner: session, expectedIdentity: session.expectedIdentity,
            publicModelID: session.model.publicModelID, profile: session.profile,
            tokenizer: tokenizer, eosTokenIDs: eos, modelType: session.model.modelType,
            firstTokenBudgetPolicy: firstTokenBudgetPolicy)
        return lifetime
    }

    func prepareAndBind(_ target: DistributedLocalServerGeneration, timeout: Duration) async throws {
        let lifetime = try await prepareGeneration(target, phase: .starting)
        try requirePreparing(target, phase: .starting)
        try responseRouter.publish(target.responses)
        startLifetimeMonitor(target, deadline: lifetime)
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
