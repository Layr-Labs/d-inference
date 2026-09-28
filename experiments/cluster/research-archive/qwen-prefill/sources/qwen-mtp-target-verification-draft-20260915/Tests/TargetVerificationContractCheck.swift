import Foundation

@main struct TargetVerificationContractCheck {
    static func main() throws {
        var passed: [String] = []
        func require(_ yes: Bool, _ message: String) throws { if !yes { throw ProbeError(message) } }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            var refused = false
            do { try body() } catch { refused = true }
            try require(refused, "Unexpected acceptance: " + name); passed.append(name)
        }
        func prepared(_ outputs: Int = 4) throws -> (PairFixture, QwenResidentMTPProposal) {
            let pair = try PairFixture(outputCount: outputs); try pair.ready()
            try pair.mtp.begin(generation: pair.generation, roundID: UUID())
            return (pair, try pair.mtp.proposed(9))
        }
        let (pair, proposal) = try prepared()
        let request = try QwenTargetVerificationRequest(proposal: proposal, generation: pair.generation)
        try require(request.maximumSteps == 2 && request.base == 5 && request.token(step: 0) == 8
                    && request.token(step: 1) == 9, "Seed/draft frame identity differs")
        var schedule = QwenLayerStageAdmittedSchedule(request: .generation(pair.agreement.request))
        for sequence in 0..<3 { try schedule.commit(pair.agreement.request.frame(sequence: sequence)) }
        for kept in 0...2 {
            let next = try request.reconciledSchedule(schedule, staged: 2, keeping: kept)
            try require(next.committedTokens == 5 + kept && next.nextSequence == 3 + kept,
                        "Retained prefix differs")
            try require(schedule.committedTokens == 5 && pair.generation.committedTokens == 5,
                        "Pure reconciliation mutated a committed session or bilateral control")
        }
        passed.append("zero/one/two prefix schedules are copied; no bilateral commit")
        let first = try request.reconciledSchedule(schedule, staged: 2, keeping: 1)
        let continued = try request.reconciledSchedule(first, staged: 2, keeping: 2, alreadyCommitted: 1)
        let stopped = try request.reconciledSchedule(first, staged: 2, keeping: 1, alreadyCommitted: 1)
        try require(continued.committedTokens == 7 && stopped.committedTokens == 6,
                    "Progressive continue/stop changed the published prefix")
        try rejects("published prefix cannot be rolled back") {
            _ = try request.reconciledSchedule(first, staged: 2, keeping: 0, alreadyCommitted: 1)
        }
        passed.append("oldest-first progressive commit preserves per-token continue/stop")
        let (lastPair, lastProposal) = try prepared(2)
        let last = try QwenTargetVerificationRequest(proposal: lastProposal, generation: lastPair.generation)
        try require(last.maximumSteps == 1, "Last output incorrectly admitted a draft input")
        try rejects("last output has only seed input") { _ = try last.frame(step: 1) }
        try rejects("retained exceeds staged") { _ = try request.reconciledSchedule(schedule, staged: 1, keeping: 2) }
        try rejects("negative retained prefix") { _ = try request.reconciledSchedule(schedule, staged: 2, keeping: -1) }
        try rejects("uncommitted prompt schedule") {
            _ = try request.reconciledSchedule(.init(request: .generation(pair.agreement.request)), staged: 2, keeping: 1)
        }
        try rejects("wrong request/epoch chain") {
            let (other, _) = try prepared()
            _ = try QwenTargetVerificationRequest(proposal: proposal, generation: other.generation)
        }
        try rejects("cancelled generation") {
            pair.generation.cancel()
            _ = try QwenTargetVerificationRequest(proposal: proposal, generation: pair.generation)
        }
        let rank0 = try QwenTargetVerificationBudget.derive(hiddenSize: 4096, vocabularySize: 248320,
            dtypeBytes: 2, rank: 0, steps: 2, bound: { $0 })
        let rank1 = try QwenTargetVerificationBudget.derive(hiddenSize: 4096, vocabularySize: 248320,
            dtypeBytes: 2, rank: 1, steps: 2, bound: { $0 })
        try require(rank0.additionalNativeBytes == 32776 && rank0.additionalHostBytes == 8192
            && rank1.additionalNativeBytes == 2019336 && rank1.additionalHostBytes == 8192,
            "Named verification rows are not fully charged")
        passed.append("actual-shape extra rows and host digest copy are separate from base/assistant allowance")
        try rejects("allocator bound smaller than logical bytes") {
            _ = try QwenTargetVerificationBudget.derive(hiddenSize: 4096, vocabularySize: 248320,
                dtypeBytes: 2, rank: 1, steps: 2, bound: { $0 - 1 })
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: [
            "passed": passed, "nativeExecution": false, "bilateralVerification": false], options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }
}
