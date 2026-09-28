import Foundation

/// Pure Foundation fixture. Root owns compilation/execution; no MLX imports.
struct CBv2OwnerPhaseObservationCheckResult: Encodable {
    let kind = "cbv2_owner_phase_observation_check"
    let acceptedChecks: Int
    let expectedFailurePaths: Int
    let nativeExecution = false
}

private enum CBv2OwnerPhaseFixtureError: Error, Equatable {
    case observation, pendingNative, pendingDeadline, assertion
}

func checkCBv2OwnerPhaseObservation() throws -> CBv2OwnerPhaseObservationCheckResult {
    func require(_ value: Bool) throws {
        if !value { throw CBv2OwnerPhaseFixtureError.assertion }
    }
    let phases: [CBv2OwnerPhase] = [.graphConstructionBegin, .graphConstructionEnd,
        .rootStagingBegin, .rootStagingEnd, .evaluationBegin, .evaluationEnd,
        .validationCommitBegin, .validationCommitEnd]
    try require(CBv2OwnerPhase.allCases == phases)
    try require(Set(phases.map(\.rawValue)).count == 8)

    var received: [CBv2OwnerPhaseObservation] = []
    var successfulChecks = 0
    for (index, phase) in phases.enumerated() {
        let value = CBv2OwnerPhaseObservation(phase: phase, tokenCount: 512,
            committedTokens: index == 7 ? 4096 : 3584)
        try value.deliver(to: { received.append($0) }, check: { successfulChecks += 1 })
    }
    try require(received.map(\.phase) == phases && successfulChecks == 0)
    try require(received.dropLast().allSatisfy { $0.committedTokens == 3584 }
        && received.last?.committedTokens == 4096 && received.allSatisfy { $0.tokenCount == 512 })

    var built = 0
    func argument() -> CBv2OwnerPhaseObservation {
        built += 1
        return .init(phase: .graphConstructionBegin, tokenCount: 512, committedTokens: 3584)
    }
    let absent: CBv2OwnerPhaseObserver? = nil
    if let absent {
        try argument().deliver(to: absent, check: { successfulChecks += 1 })
    }
    try require(built == 0 && successfulChecks == 0)

    let committed = received[7]
    var checksOnThrow = 0
    do {
        try committed.deliver(to: { _ in throw CBv2OwnerPhaseFixtureError.observation },
            check: { checksOnThrow += 1 })
        throw CBv2OwnerPhaseFixtureError.assertion
    } catch CBv2OwnerPhaseFixtureError.observation {}
    try require(checksOnThrow == 1)
    do {
        try committed.deliver(to: { _ in throw CBv2OwnerPhaseFixtureError.observation },
            check: { throw CBv2OwnerPhaseFixtureError.pendingNative })
        throw CBv2OwnerPhaseFixtureError.assertion
    } catch CBv2OwnerPhaseFixtureError.pendingNative {}
    do {
        try committed.deliver(to: { _ in throw CBv2OwnerPhaseFixtureError.observation },
            check: { throw CBv2OwnerPhaseFixtureError.pendingDeadline })
        throw CBv2OwnerPhaseFixtureError.assertion
    } catch CBv2OwnerPhaseFixtureError.pendingDeadline {}
    return .init(acceptedChecks: 6, expectedFailurePaths: 3)
}
