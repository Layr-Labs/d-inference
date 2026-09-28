import Foundation

/// CPU command identity shared by solo and rank resident owners. Returning from
/// beforeRequest permits this one admitted step; it does not admit resources.
struct QwenLongPrefillResidentRequestStep: Encodable, Equatable {
    let ordinal: Int
    let excludedWarmup: Bool
    let requestID: UUID
    let recordedRequestFingerprint: String
    let promptFileSHA256: String

    static func validate(_ steps: [Self]) throws {
        guard (1...4).contains(steps.count) else {
            throw ProbeError("Resident request sequence requires one through four steps")
        }
        var identities = Set<UUID>()
        var measured = false
        for (ordinal, step) in steps.enumerated() {
            guard step.ordinal == ordinal, identities.insert(step.requestID).inserted,
                  isSHA256(step.recordedRequestFingerprint), isSHA256(step.promptFileSHA256),
                  !measured || !step.excludedWarmup else {
                throw ProbeError("Resident request sequence changed its order, identity or warmup prefix")
            }
            if !step.excludedWarmup { measured = true }
        }
        guard measured else { throw ProbeError("Resident request sequence requires a measured request") }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
}

/// A synchronous callback sequencer, with no native ownership or IO. The trusted
/// private owner must make request return CPU metadata only, after its lifecycle
/// lease and native autorelease scope have both returned. A thrown permission,
/// request, publication or check stops the sequence; no callback is retried.
func runQwenLongPrefillResidentSteps<Result>(steps: [QwenLongPrefillResidentRequestStep],
    beforeRequest: (QwenLongPrefillResidentRequestStep) throws -> Void,
    request: (QwenLongPrefillResidentRequestStep) throws -> Result,
    onRequestResult: (QwenLongPrefillResidentRequestStep, Result) throws -> Void,
    check: () throws -> Void
) throws -> [Result] {
    try QwenLongPrefillResidentRequestStep.validate(steps)
    var results: [Result] = []
    results.reserveCapacity(steps.count)
    for step in steps {
        try check()
        try beforeRequest(step)
        try check()
        let result = try request(step)
        try check()
        try onRequestResult(step, result)
        try check()
        results.append(result)
    }
    return results
}
