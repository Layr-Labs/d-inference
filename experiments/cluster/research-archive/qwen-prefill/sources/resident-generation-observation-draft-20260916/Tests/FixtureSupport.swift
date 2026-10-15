import Foundation

enum FixtureFailure: Error { case assertion(String), observation, native, reservation }

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw FixtureFailure.assertion(message) }
}

func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch { return }
    throw FixtureFailure.assertion("Expected refusal: " + label)
}

func identity(rank: Int = 0, prompt: Int = 32, chunk: Int = 16, output: Int = 2,
              policy: String = "oneChunkLookahead") -> QwenGenerationPhaseIdentity {
    let digest = String(repeating: "a", count: 64)
    return .init(requestID: "11111111-1111-4111-8111-111111111111",
        membershipEpoch: "22222222-2222-4222-8222-222222222222",
        requestFingerprint: digest, agreementFingerprint: digest, profileFingerprint: digest,
        sourceConfigurationSHA256: digest, artifactAggregateSHA256: digest,
        storageCommitmentSHA256: digest, planFingerprint: digest, stageFingerprint: digest,
        buildSHA256: digest, numericalPolicySHA256: digest, rank: rank,
        promptCount: prompt, chunkSize: chunk, outputCount: output, prefillPolicy: policy)
}

func fixtureBudget(_ identity: QwenGenerationPhaseIdentity) throws -> QwenGenerationPhaseBudget {
    // Deliberately fabricated host allocation bound, never native authority.
    try .derive(identity: identity, hostAllocationBound: { (($0 + 4095) / 4096 + 1) * 4096 })
}

func event(_ phase: QwenGenerationPhase, frame: QwenGenerationPhaseFrame? = nil,
           local: Int? = nil, agreed: Int? = nil) -> QwenGenerationPhaseObservation {
    .init(phase: phase, frame: frame, localCommittedTokens: local, agreedCommittedTokens: agreed)
}

func recorder(_ id: QwenGenerationPhaseIdentity = identity(),
    clock: @escaping () throws -> UInt64,
    reservation: @escaping () throws -> Void = {}) throws -> QwenGenerationPhaseRecorder {
    try .forCPUFixture(identity: id, budget: fixtureBudget(id), clock: clock,
        reservationCheck: reservation)
}
