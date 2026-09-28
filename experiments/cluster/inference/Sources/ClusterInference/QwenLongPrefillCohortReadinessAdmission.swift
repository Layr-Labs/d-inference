import Foundation

enum QwenLongPrefillCohortReadinessCase: String, Codable, CaseIterable {
    case match
    case warmupMismatch = "warmup-mismatch"
}

/// Both rank intents are admitted before MLX or Collective setup. These are
/// synthetic metadata fixtures, not loaded-source or actual-resource admission.
struct QwenLongPrefillCohortReadinessAdmission {
    let epoch: String
    let fixtureCase: QwenLongPrefillCohortReadinessCase
    private let agreements: [QwenLongPrefillResidentCohortAgreement]

    init(options: Options) throws {
        try Self.validateOptions(options)
        let epoch = options.epoch!, fixtureCase = options.cohortReadinessCase!
        let fixture = try QwenLongPrefillResidentCohortFixture()
        let requests = try (0..<3).map { ordinal in
            let requestEpoch = ordinal == 0 ? epoch : String(sha256(Data(
                "qwen-cohort-readiness-fixture-request-v1|\(epoch)|\(ordinal)".utf8)).prefix(32))
            let prompt = ordinal == 1 ? fixture.promptB : fixture.promptA
            let request = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
                requestID: QwenLayerStageRankAdmission.requestID(epoch: requestEpoch),
                batchSize: 1, promptCount: 8192, chunkSize: 512, outputCount: 1)
            let local = try QwenRegistered9BLongPrefillReferenceAdmission(
                configuration: fixture.configuration,
                expectedArtifactAggregateSHA256: QwenLongPrefillResidentRankFixture.artifactSHA256,
                promptData: prompt, expectedPromptSHA256: sha256(prompt), request: request,
                arithmetic: fixture.arithmetic, stageCut: 12)
            return QwenLongPrefillResidentRankRequest(epoch: requestEpoch, local: local)
        }
        let rankOptions = try fixture.options(requests[0])
        let first = try QwenLongPrefillResidentCohortAgreement(
            options: rankOptions, requests: requests, warmupCount: 1)
        let second = try QwenLongPrefillResidentCohortAgreement(options: rankOptions,
            requests: requests, warmupCount: fixtureCase == .match ? 1 : 0)
        self.epoch = epoch; self.fixtureCase = fixtureCase
        agreements = [first, second]
    }

    func agreement(forRank rank: Int) throws -> QwenLongPrefillResidentCohortAgreement {
        guard (0..<2).contains(rank) else { throw ProbeError("Readiness fixture requires rank zero or one") }
        return agreements[rank]
    }

    static func validateArguments(_ arguments: [String], options: Options) throws {
        try validateOptions(options)
        let allowed: Set<String> = ["--mode", "--transport", "--epoch", "--cohort-readiness-case", "--timeout-seconds"]
        guard arguments.count == allowed.count * 2 else {
            throw ProbeError("Cohort readiness check requires exactly five explicit flag/value pairs")
        }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index]
            guard allowed.contains(flag), values[flag] == nil else {
                throw ProbeError("Cohort readiness check rejects extra or duplicate flags")
            }
            values[flag] = arguments[index + 1]
        }
        guard Set(values.keys) == allowed,
              values["--mode"] == options.mode.rawValue,
              values["--transport"] == options.transport.rawValue,
              values["--epoch"] == options.epoch,
              values["--cohort-readiness-case"] == options.cohortReadinessCase?.rawValue,
              values["--timeout-seconds"] == String(options.timeoutSeconds) else {
            throw ProbeError("Cohort readiness check requires exact canonical argument values")
        }
    }

    static func validateOptions(_ options: Options) throws {
        guard options.mode == .qwenLongPrefillCohortReadinessCheck,
              options.transport == .loopbackTest, options.cohortReadinessCase != nil,
              let epoch = options.epoch, (1...30).contains(options.timeoutSeconds) else {
            throw ProbeError("Cohort readiness check requires an explicit case, loopback epoch and timeout between 1 and 30 seconds")
        }
        _ = try QwenLayerStageRankAdmission.requestID(epoch: epoch)
        guard options.modelDirectory == nil, !options.synthetic, !options.localCorrectness,
              options.expectedArtifactAggregateSHA256 == nil,
              options.tokensFile == nil, options.teacherTokensFile == nil, options.logitsFile == nil,
              options.stageCut == nil, options.stagePrefillPolicy == nil, options.stageLogitsDType == nil,
              options.longPromptSHA256 == nil, options.soloReferenceFile == nil,
              options.soloReferenceSHA256 == nil, options.soloBaselineEvidenceSHA256 == nil,
              options.prefillPhaseTraceFile == nil, options.prefillOwnerTraceFile == nil,
              options.routingFile == nil, options.routingReplayFile == nil,
              !options.gemmaDiagnostic, options.gemmaBoundaryFile == nil,
              options.partition == .ffn, options.attentionOutputPrecision == .native,
              options.ffnOutputPrecision == .native, options.ffnBranchPrecision == .native,
              options.executionPath == .ordinary, options.syntheticDType == "float32",
              options.syntheticProfile == "tiny", options.promptCount == 128, options.chunkSize == 128,
              options.decodeCount == 16, options.repeats == 3, options.warmups == 1, options.seed == 7 else {
            throw ProbeError("Cohort readiness check accepts no model, workload, source, trace or precision options")
        }
    }
}
