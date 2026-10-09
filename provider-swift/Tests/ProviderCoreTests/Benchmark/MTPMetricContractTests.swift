import MLXLMCommon
import Testing

@testable import ProviderBenchmark

@Suite("MTP execution and cost-learning evidence")
struct MTPMetricContractTests {
    private func seedOnly() -> CBv2MTPMetrics {
        var value = CBv2MTPMetrics()
        value.maxAutomaticRectangularTokens = 8
        value.decodeRowBucket = 8
        value.seedSteps = 1
        value.depthSelections = [0: 127, 3: 1]
        value.controllerFallbacks = ["automatic_rectangular_limit": 127]
        return value
    }

    private func validateSeed(_ value: CBv2MTPMetrics) throws {
        try MTPBenchmarkRunner.validateMetrics(MTPBenchmarkMetrics(engineMetrics: value),
            mode: .fixed(verificationWidth: 4), batchSize: 8,
            adaptiveDraftingExpected: true, allowedSkipReasons: [])
    }

    private func executed(depth: Int = 1) -> CBv2MTPMetrics {
        var value = CBv2MTPMetrics()
        value.maxAutomaticRectangularTokens = 8
        value.decodeRowBucket = 1
        value.rounds = 8
        value.seedSteps = 1
        value.draftedTokens = 8 * depth
        value.acceptedTokens = 7
        value.emittedTokens = 15
        value.rectangularVerificationRounds = 8
        value.perPositionAccepted = Array(repeating: 7, count: depth)
        value.depthSelections = [0: 8, depth: 9]
        value.controllerFallbacks = ["tail_depth": 2]
        return value
    }

    private func validateExecution(_ value: CBv2MTPMetrics,
                                   mode: MTPBenchmarkMode = .adaptive,
                                   requireCost: Bool) throws {
        try MTPBenchmarkRunner.validateMetrics(MTPBenchmarkMetrics(engineMetrics: value),
            mode: mode, batchSize: 1, adaptiveDraftingExpected: true,
            allowedSkipReasons: [], requireAutomaticVerification: true,
            requireCostLearningEvidence: requireCost)
    }

    @Test func seedBeforeBatchFillIsNotADraftRound() throws {
        try validateSeed(seedOnly())
        var zero = seedOnly()
        zero.seedSteps = 0
        zero.depthSelections = [0: 127]
        try validateSeed(zero)
    }

    @Test func unexplainedSeedOrPositiveSelectionsAreRejected() throws {
        for variant in 0..<5 {
            var value = seedOnly()
            switch variant {
            case 0: value.seedSteps = 0
            case 1: value.depthSelections = [0: 127]
            case 2: value.depthSelections = [0: 127, 3: 2]
            case 3: value.depthSelections = [-1: 1, 0: 127]
            default:
                value.seedSteps = .max
                value.depthSelections = [0: 127, 1: .max, 2: 1]
            }
            #expect(throws: MTPBenchmarkError.self) { try validateSeed(value) }
        }
    }

    @Test func seedsNeverExcuseSpeculativeResidueOrAnUnexplainedFallback() throws {
        for variant in 0..<9 {
            var value = seedOnly()
            switch variant {
            case 0: value.rounds = 1
            case 1: value.draftedTokens = 1
            case 2: value.acceptedTokens = 1
            case 3: value.emittedTokens = 1
            case 4: value.rectangularVerificationRounds = 1
            case 5: value.serialVerificationRounds = 1
            case 6: value.totalRoundWallTimeNanos = 1
            case 7: value.perPositionAccepted = [0]
            default: value.controllerFallbacks = [:]
            }
            #expect(throws: MTPBenchmarkError.self) { try validateSeed(value) }
        }
    }

    @Test func cancelledLearningWindowCanStillProveCorrectnessExecution() throws {
        let value = executed()
        try validateExecution(value, requireCost: false)
        #expect(throws: MTPBenchmarkError.self) { try validateExecution(value, requireCost: true) }
    }

    @Test func costExemptionRequiresActualVerificationAndAcceptedPositionTracking() throws {
        for variant in 0..<4 {
            var value = executed()
            switch variant {
            case 0: value.rectangularVerificationRounds = 0
            case 1: value.perPositionAccepted = []
            case 2: value.rounds = 0
            default: value.draftedTokens = 0
            }
            #expect(throws: MTPBenchmarkError.self) { try validateExecution(value, requireCost: false) }
        }
    }

    @Test func fixedDepthMustHaveBeenRepresentedInFinalizedWork() throws {
        var value = executed(depth: 2)
        let mode = try MTPBenchmarkMode.fixed(verificationWidth: 3)
        try validateExecution(value, mode: mode, requireCost: false)
        #expect(throws: MTPBenchmarkError.self) { try validateExecution(value, mode: mode, requireCost: true) }
        value.perPositionAccepted = [7]
        #expect(throws: MTPBenchmarkError.self) { try validateExecution(value, mode: mode, requireCost: false) }
    }

    @Test func productionCorrectnessStillRejectsSerialVerification() throws {
        var value = executed()
        value.serialVerificationRounds = 1
        #expect(throws: MTPBenchmarkError.self) { try validateExecution(value, requireCost: false) }
    }
}
