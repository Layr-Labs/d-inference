import Foundation
import MLXLMCommon
import ProviderCore

public struct MTPBenchmarkPrompt: Sendable {
    public let name: String
    public let tokenIDs: [Int]

    public init(name: String, tokenIDs: [Int]) {
        self.name = name
        self.tokenIDs = tokenIDs
    }
}

public struct MTPBenchmarkSession: Sendable {
    public let engine: any CBv2Engine
    private let metricsProvider: @Sendable () async -> MTPBenchmarkMetrics

    public init(
        engine: any CBv2Engine,
        metrics: @escaping @Sendable () async -> MTPBenchmarkMetrics
    ) {
        self.engine = engine
        self.metricsProvider = metrics
    }

    public func metrics() async -> MTPBenchmarkMetrics { await metricsProvider() }
}

public struct MTPBenchmarkSessionFactory: Sendable {
    public let make: @Sendable (MTPBenchmarkMode, Int) async throws -> MTPBenchmarkSession

    public init(
        make: @escaping @Sendable (MTPBenchmarkMode, Int) async throws -> MTPBenchmarkSession
    ) {
        self.make = make
    }
}

public struct MTPBenchmarkConfiguration: Sendable {
    public let prompts: [MTPBenchmarkPrompt]
    public let batchSizes: [Int]
    public let modes: [MTPBenchmarkMode]
    public let maxTokensPerRow: Int
    public let purpose: MTPBenchmarkPurpose
    public let mtpExpectation: MTPBenchmarkMTPExpectation
    public let stopPolicy: MTPBenchmarkStopPolicy
    public let warmupIterations: Int
    public let measurementRepetitions: Int
    public let modeOrderSeed: UInt64
    public let adaptiveDraftingBatchSizes: Set<Int>
    public let allowedSkipReasons: Set<String>
    public let runFingerprint: String
    public let checkpointDestination: MTPBenchmarkReportDestination?
    /// Elapsed run budget checked around factory creation, submission,
    /// consumption, and shutdown. Synchronous MLX calls are not safely
    /// preemptible, so env-gated live tests additionally require the external
    /// process-group supervisor in scripts/run-mtp-benchmark.py.
    public let deadline: Duration

    public init(
        prompts: [MTPBenchmarkPrompt],
        batchSizes: [Int] = [1, 2, 4, 8],
        modes: [MTPBenchmarkMode] = MTPBenchmarkRunner.standardModes,
        maxTokensPerRow: Int = 64,
        purpose: MTPBenchmarkPurpose,
        mtpExpectation: MTPBenchmarkMTPExpectation = .active,
        stopPolicy: MTPBenchmarkStopPolicy,
        warmupIterations: Int = 0,
        measurementRepetitions: Int = 1,
        modeOrderSeed: UInt64 = 0x4d545032,
        adaptiveDraftingBatchSizes: Set<Int>? = nil,
        allowedSkipReasons: Set<String> = [],
        runFingerprint: String = UUID().uuidString,
        checkpointDestination: MTPBenchmarkReportDestination? = nil,
        deadline: Duration = .seconds(3600)
    ) {
        self.prompts = prompts
        self.batchSizes = batchSizes
        self.modes = modes
        self.maxTokensPerRow = max(1, maxTokensPerRow)
        self.purpose = purpose
        self.mtpExpectation = mtpExpectation
        self.stopPolicy = stopPolicy
        self.warmupIterations = warmupIterations
        self.measurementRepetitions = measurementRepetitions
        self.modeOrderSeed = modeOrderSeed
        self.adaptiveDraftingBatchSizes = adaptiveDraftingBatchSizes ?? Set(batchSizes)
        self.allowedSkipReasons = allowedSkipReasons
        self.runFingerprint = runFingerprint
        self.checkpointDestination = checkpointDestination
        self.deadline = deadline
    }
}

public enum MTPBenchmarkRunner {
    public static let standardModes: [MTPBenchmarkMode] = {
        var modes: [MTPBenchmarkMode] = [.targetOnly]
        modes.append(contentsOf: (1...8).map {
            MTPBenchmarkMode(kind: .fixed, verificationWidth: $0)
        })
        modes.append(.adaptive)
        return modes
    }()

    private struct CaseKey: Hashable, Sendable {
        let mode: MTPBenchmarkMode
        let batchSize: Int
    }

    private struct MeasuredRow: Sendable {
        let promptName: String
        let tokenIDs: [Int]
        let tokenTimestampsNanoseconds: [UInt64]
        let timing: MTPBenchmarkStreamTiming
        let finishReason: String
    }

    private struct BatchMeasurement: Sendable {
        let rows: [MeasuredRow]
        let aggregateDecodeTokensPerSecond: Double
    }

    private struct CaseSample: Sendable {
        let batch: BatchMeasurement
        let metrics: MTPBenchmarkMetrics
    }

    private enum BatchTaskResult: Sendable {
        case row(Int, MeasuredRow)
    }

    public static func run(
        target: MTPBenchmarkArtifactFacts,
        assistant: MTPBenchmarkArtifactFacts,
        hardware: MTPBenchmarkHardware,
        configuration: MTPBenchmarkConfiguration,
        sessions: MTPBenchmarkSessionFactory
    ) async throws -> MTPBenchmarkReport {
        let startedAt = ContinuousClock.now
        let startedDate = Date()
        try validate(configuration)
        try validateArtifactBoundary(target, label: "target")
        try validateArtifactBoundary(assistant, label: "assistant")

        let deadlineAt = startedAt + configuration.deadline
        let coverage = MTPBenchmarkCoverage.shortContextMatrix(
            target: target, assistant: assistant, purpose: configuration.purpose)
        let orderedCases = caseOrder(configuration: configuration)
        let tokenEvidenceSalt = MTPBenchmarkDigest.randomSalt()
        var results: [MTPBenchmarkCaseResult] = []
        var baselineTokens: [Int: [[Int]]] = [:]
        var baselineFinishReasons: [Int: [String]] = [:]

        func report(complete: Bool) -> MTPBenchmarkReport {
            MTPBenchmarkReport(
                runFingerprint: configuration.runFingerprint,
                buildConfiguration: .current,
                purpose: configuration.purpose,
                mtpExpectation: configuration.mtpExpectation,
                stopPolicy: configuration.stopPolicy,
                startedAt: startedDate,
                completedAt: complete ? Date() : nil,
                complete: complete,
                expectedCaseCount: orderedCases.count,
                target: target,
                assistant: assistant,
                hardware: hardware,
                maxTokensPerRow: configuration.maxTokensPerRow,
                warmupIterations: configuration.warmupIterations,
                measurementRepetitions: configuration.measurementRepetitions,
                modeOrderSeed: configuration.modeOrderSeed,
                coverage: coverage,
                elapsedMs: milliseconds(ContinuousClock.now - startedAt),
                cases: results)
        }

        for key in orderedCases {
            try requireBeforeDeadline(deadlineAt)
            for _ in 0..<configuration.warmupIterations {
                _ = try await runSample(
                    key: key,
                    configuration: configuration,
                    deadlineAt: deadlineAt,
                    sessions: sessions)
            }
            var samples: [CaseSample] = []
            for _ in 0..<configuration.measurementRepetitions {
                samples.append(try await runSample(
                    key: key,
                    configuration: configuration,
                    deadlineAt: deadlineAt,
                    sessions: sessions))
            }
            try validateRepetitionConsistency(samples, key: key)

            let sampleTokens = samples.map { $0.batch.rows.map(\.tokenIDs) }
            let sampleReasons = samples.map { $0.batch.rows.map(\.finishReason) }
            let canonicalTokens = sampleTokens[0]
            if key.mode.kind == .targetOnly {
                baselineTokens[key.batchSize] = canonicalTokens
                baselineFinishReasons[key.batchSize] = sampleReasons[0]
            } else {
                guard let baseline = baselineTokens[key.batchSize],
                      let baselineReasons = baselineFinishReasons[key.batchSize]
                else {
                    throw MTPBenchmarkError.missingTargetOnlyBaseline
                }
                for tokens in sampleTokens {
                    let mismatches = parityMismatches(baseline: baseline, candidate: tokens)
                    guard mismatches.isEmpty, baseline.count == tokens.count else {
                        throw MTPBenchmarkError.tokenParityMismatch(
                            mode: key.mode.label,
                            batchSize: key.batchSize,
                            rows: mismatches)
                    }
                }
                // Identical tokens with a different terminal reason is still
                // an OpenAI-visible behavior divergence (for example EOS
                // exactly at the budget reported as "stop" by target-only but
                // "length" by MTP). Parity certifies both.
                for reasons in sampleReasons where reasons != baselineReasons {
                    let rows = zip(reasons, baselineReasons).enumerated()
                        .filter { $0.element.0 != $0.element.1 }
                        .map(\.offset)
                    throw MTPBenchmarkError.invalidMetrics(
                        "\(key.mode.label), B=\(key.batchSize) finish reasons diverge "
                            + "from the target-only baseline at rows \(rows)")
                }
            }

            results.append(aggregate(
                samples: samples,
                key: key,
                performanceEligible: configuration.purpose.performanceEligible,
                tokenEvidenceSalt: tokenEvidenceSalt))
            if let checkpointDestination = configuration.checkpointDestination {
                try requireBeforeDeadline(deadlineAt)
                try report(complete: false).write(to: checkpointDestination)
                try requireBeforeDeadline(deadlineAt)
            }
        }

        try requireBeforeDeadline(deadlineAt)
        try validateArtifactBoundary(target, label: "target")
        try validateArtifactBoundary(assistant, label: "assistant")
        let final = report(complete: true)
        if let checkpointDestination = configuration.checkpointDestination {
            try final.write(to: checkpointDestination)
            try requireBeforeDeadline(deadlineAt)
        }
        return final
    }

    private static func validate(_ configuration: MTPBenchmarkConfiguration) throws {
        guard !configuration.prompts.isEmpty else { throw MTPBenchmarkError.emptyPromptCorpus }
        guard configuration.modes.contains(.targetOnly) else {
            throw MTPBenchmarkError.missingTargetOnlyBaseline
        }
        guard configuration.warmupIterations >= 0 else {
            throw MTPBenchmarkError.invalidWarmupIterations(configuration.warmupIterations)
        }
        guard configuration.measurementRepetitions > 0 else {
            throw MTPBenchmarkError.invalidMeasurementRepetitions(
                configuration.measurementRepetitions)
        }
        guard !configuration.runFingerprint.isEmpty else {
            throw MTPBenchmarkError.invalidStopPolicy("run fingerprint is empty")
        }
        guard configuration.mtpExpectation.isWellFormed else {
            throw MTPBenchmarkError.invalidMTPExpectation(
                "expected-inactive mode requires a nonempty exact reason or prefix; active mode must not carry inactive reasons")
        }
        if configuration.purpose == .productionPerformance,
           configuration.mtpExpectation.expectsInactive
        {
            throw MTPBenchmarkError.invalidMTPExpectation(
                "production performance cannot certify expected-inactive target-only fallback")
        }
        if configuration.purpose == .productionPerformance,
           MTPBenchmarkBuildConfiguration.current == .debug
        {
            throw MTPBenchmarkError.invalidBuildConfiguration(
                "production performance requires a release build")
        }
        for batchSize in configuration.batchSizes where batchSize <= 0 {
            throw MTPBenchmarkError.invalidBatchSize(batchSize)
        }
        guard Set(configuration.batchSizes).count == configuration.batchSizes.count else {
            throw MTPBenchmarkError.invalidBatchSize(-1)
        }
        guard Set(configuration.modes).count == configuration.modes.count else {
            throw MTPBenchmarkError.invalidVerificationWidth(-1)
        }
        for mode in configuration.modes where mode.kind == .fixed {
            guard let width = mode.verificationWidth, (1...8).contains(width) else {
                throw MTPBenchmarkError.invalidVerificationWidth(mode.verificationWidth ?? -1)
            }
        }
        switch (configuration.purpose, configuration.stopPolicy.kind) {
        case (.rawParityStress, .rawFixedLengthNoStop):
            guard configuration.stopPolicy.stopTokenIDs.isEmpty else {
                throw MTPBenchmarkError.invalidStopPolicy(
                    "raw parity must not carry stop token IDs")
            }
        case (.productionCorrectness, .productionTargetEOS),
             (.productionPerformance, .productionTargetEOS):
            guard !configuration.stopPolicy.stopTokenIDs.isEmpty else {
                throw MTPBenchmarkError.invalidStopPolicy(
                    "production runs require the target EOS/stop token IDs")
            }
        default:
            throw MTPBenchmarkError.invalidStopPolicy(
                "purpose \(configuration.purpose.rawValue) does not match \(configuration.stopPolicy.kind.rawValue)")
        }
    }

    private static func caseOrder(
        configuration: MTPBenchmarkConfiguration
    ) -> [CaseKey] {
        var generator = SeededGenerator(seed: configuration.modeOrderSeed)
        var baselines = configuration.batchSizes.map {
            CaseKey(mode: .targetOnly, batchSize: $0)
        }
        baselines.seededShuffle(using: &generator)
        var candidates = configuration.modes
            .filter { $0.kind != .targetOnly }
            .flatMap { mode in
                configuration.batchSizes.map { CaseKey(mode: mode, batchSize: $0) }
            }
        candidates.seededShuffle(using: &generator)
        return baselines + candidates
    }

    private static func runSample(
        key: CaseKey,
        configuration: MTPBenchmarkConfiguration,
        deadlineAt: ContinuousClock.Instant,
        sessions: MTPBenchmarkSessionFactory
    ) async throws -> CaseSample {
        try requireBeforeDeadline(deadlineAt)
        let session: MTPBenchmarkSession
        do {
            session = try await sessions.make(key.mode, key.batchSize)
        } catch {
            if ContinuousClock.now >= deadlineAt {
                throw MTPBenchmarkError.deadlineExceeded
            }
            throw error
        }
        if ContinuousClock.now >= deadlineAt {
            await session.engine.shutdown()
            throw MTPBenchmarkError.deadlineExceeded
        }
        var didShutdown = false
        do {
            let before = await session.metrics()
            try requireBeforeDeadline(deadlineAt)
            try validateActivation(
                metrics: before,
                mode: key.mode,
                expectation: configuration.mtpExpectation,
                beforeRun: true)
            let batch = try await runBatch(
                engine: session.engine,
                prompts: configuration.prompts,
                batchSize: key.batchSize,
                maxTokens: configuration.maxTokensPerRow,
                stopPolicy: configuration.stopPolicy,
                deadlineAt: deadlineAt)
            let metrics = await session.metrics()
            try requireBeforeDeadline(deadlineAt)
            try validateMetrics(
                metrics,
                mode: key.mode,
                batchSize: key.batchSize,
                adaptiveDraftingExpected: configuration.adaptiveDraftingBatchSizes.contains(
                    key.batchSize),
                allowedSkipReasons: configuration.allowedSkipReasons,
                expectation: configuration.mtpExpectation,
                requireAutomaticVerification: configuration.purpose != .rawParityStress)
            await session.engine.shutdown()
            didShutdown = true
            try requireBeforeDeadline(deadlineAt)
            return CaseSample(batch: batch, metrics: metrics)
        } catch {
            let primaryError = error
            if !didShutdown {
                await session.engine.shutdown()
            }
            if ContinuousClock.now >= deadlineAt {
                throw MTPBenchmarkError.deadlineExceeded
            }
            throw primaryError
        }
    }

    static func validateMetrics(
        _ metrics: MTPBenchmarkMetrics,
        mode: MTPBenchmarkMode,
        batchSize: Int,
        adaptiveDraftingExpected: Bool,
        allowedSkipReasons: Set<String>,
        expectation: MTPBenchmarkMTPExpectation = .active,
        requireAutomaticVerification: Bool = false
    ) throws {
        try validateActivation(
            metrics: metrics,
            mode: mode,
            expectation: expectation,
            beforeRun: false)
        // Production evidence certifies the PRODUCTION mechanism: every
        // active MTP case must have run the automatic verifier with zero
        // serial rounds (a stray DARKBLOOM_MTP_VERIFICATION_MODE in the
        // launching shell must not certify the serial oracle). Raw parity
        // stays mode-agnostic — it is the serial/rectangular diagnostic
        // vehicle. Target-authoritative token/finish-reason parity against
        // the target-only baseline is enforced unconditionally in `run`.
        if requireAutomaticVerification, mode.requestsMTP, !expectation.expectsInactive {
            guard metrics.verificationMode == "automatic",
                  (metrics.serialVerificationRounds ?? 0) == 0
            else {
                throw MTPBenchmarkError.invalidMetrics(
                    "\(mode.label), B=\(batchSize) production evidence requires the "
                        + "automatic verifier (mode=\(metrics.verificationMode ?? "nil"))")
            }
        }
        let unexpectedSkips = Set(metrics.skippedRows.keys).subtracting(allowedSkipReasons)
        guard unexpectedSkips.isEmpty else {
            throw MTPBenchmarkError.invalidMetrics(
                "\(mode.label), B=\(batchSize) reported unapproved skips \(unexpectedSkips.sorted())")
        }
        let expectedBucket = decodeRowBucket(batchSize)
        switch mode.kind {
        case .targetOnly:
            try validateNoSpeculativeWork(metrics, context: "target-only baseline")
        case .fixed:
            if expectation.expectsInactive {
                try validateNoSpeculativeWork(metrics, context: "\(mode.label), B=\(batchSize)")
                return
            }
            let expectedDepth = (mode.verificationWidth ?? 1) - 1
            if try validateAutomaticDepthLimitFallback(
                metrics, batchSize: batchSize, requestedDepth: expectedDepth)
            {
                return
            }
            guard observedBucket(metrics, expectedBucket: expectedBucket) else {
                throw MTPBenchmarkError.invalidMetrics(
                    "\(mode.label), B=\(batchSize) never observed decode-row bucket \(expectedBucket)")
            }
            guard metrics.depthSelections[String(expectedDepth), default: 0] > 0 else {
                throw MTPBenchmarkError.invalidMetrics(
                    "\(mode.label), B=\(batchSize) never selected requested depth \(expectedDepth)")
            }
            if expectedDepth > 0 {
                guard metrics.rounds > 0, metrics.proposedTokens > 0 else {
                    throw MTPBenchmarkError.invalidMetrics(
                        "\(mode.label), B=\(batchSize) did not execute active draft rounds")
                }
                guard metrics.costInputs.contains(where: {
                    $0.decodeRowBucket == expectedBucket
                        && $0.draftDepth == expectedDepth
                        && $0.sampleCount > 0
                }) else {
                    throw MTPBenchmarkError.invalidMetrics(
                        "\(mode.label), B=\(batchSize) did not measure requested depth/bucket")
                }
            }
        case .adaptive:
            if expectation.expectsInactive {
                try validateNoSpeculativeWork(metrics, context: "adaptive B=\(batchSize)")
                return
            }
            guard observedBucket(metrics, expectedBucket: expectedBucket) else {
                throw MTPBenchmarkError.invalidMetrics(
                    "adaptive B=\(batchSize) never observed decode-row bucket \(expectedBucket)")
            }
            if adaptiveDraftingExpected {
                if try validateAutomaticAdaptiveWithinCap(metrics, batchSize: batchSize) {
                    return
                }
                guard metrics.rounds > 0, metrics.proposedTokens > 0 else {
                    throw MTPBenchmarkError.invalidMetrics(
                        "adaptive B=\(batchSize) was expected to draft but did not")
                }
                guard metrics.depthSelections.contains(where: {
                    (Int($0.key) ?? 0) > 0 && $0.value > 0
                }) else {
                    throw MTPBenchmarkError.invalidMetrics(
                        "adaptive B=\(batchSize) never selected a nonzero depth")
                }
                guard metrics.costInputs.contains(where: {
                    $0.decodeRowBucket == expectedBucket
                        && $0.draftDepth > 0
                        && $0.sampleCount > 0
                }) else {
                    throw MTPBenchmarkError.invalidMetrics(
                        "adaptive B=\(batchSize) lacks positive-depth cost evidence for requested bucket \(expectedBucket)")
                }
            }
        }
    }

    private static func validateAutomaticDepthLimitFallback(
        _ metrics: MTPBenchmarkMetrics,
        batchSize: Int,
        requestedDepth: Int
    ) throws -> Bool {
        guard metrics.verificationMode == "automatic",
              let maxRectangularTokens = metrics.maxAutomaticRectangularTokens,
              batchSize * (requestedDepth + 1) > maxRectangularTokens
        else { return false }

        let hasPositiveDepth = metrics.depthSelections.contains {
            (Int($0.key) ?? 0) > 0 && $0.value > 0
        }
        let positiveCosts = metrics.costInputs.filter { $0.draftDepth > 0 && $0.sampleCount > 0 }
        let costsStayWithinLimit = positiveCosts.allSatisfy {
            $0.decodeRowBucket * ($0.draftDepth + 1) <= maxRectangularTokens
        }
        guard metrics.controllerFallbacks["automatic_rectangular_limit", default: 0] > 0,
              costsStayWithinLimit,
              (metrics.serialVerificationRounds ?? 0) == 0
        else {
            throw MTPBenchmarkError.invalidMetrics(
                "automatic fixed-depth fallback B=\(batchSize) escaped its rectangular limit")
        }
        if hasPositiveDepth {
            // The depth controller intentionally refuses cost attribution
            // when the finalized depth differs from its requested depth, so
            // clamped rounds may record no positive cost inputs at all.
            guard metrics.rounds > 0,
                  metrics.proposedTokens > 0,
                  (metrics.rectangularVerificationRounds ?? 0) > 0
            else {
                throw MTPBenchmarkError.invalidMetrics(
                    "automatic fixed-depth fallback B=\(batchSize) lacks clamped-depth evidence")
            }
            return true
        }
        guard metrics.selectedDepth == 0,
              metrics.depthSelections["0", default: 0] > 0,
              metrics.rounds == 0,
              metrics.seedRows == 0,
              metrics.proposedTokens == 0,
              metrics.acceptedDraftTokens == 0,
              metrics.committedTokens == 0,
              metrics.acceptanceByPosition.isEmpty,
              metrics.conditionalAcceptance.isEmpty,
              metrics.skippedRows.isEmpty,
              metrics.costInputs.isEmpty,
              (metrics.totalRoundWallTimeNanos ?? 0) == 0,
              metrics.assistantTimeNanos == nil,
              metrics.targetVerifyTimeNanos == nil,
              (metrics.rectangularVerificationRounds ?? 0) == 0
        else {
            throw MTPBenchmarkError.invalidMetrics(
                "automatic fixed-depth fallback B=\(batchSize) reported uncategorized work")
        }
        return true
    }

    /// Adaptive drafting cannot be demanded when even depth one exceeds the
    /// automatic rectangular work cap at the submitted batch size. Any
    /// drafting that does happen (for example after tail rows drain) must
    /// stay rectangular and inside the cap.
    private static func validateAutomaticAdaptiveWithinCap(
        _ metrics: MTPBenchmarkMetrics,
        batchSize: Int
    ) throws -> Bool {
        guard metrics.verificationMode == "automatic",
              let maxRectangularTokens = metrics.maxAutomaticRectangularTokens,
              batchSize * 2 > maxRectangularTokens
        else { return false }

        let positiveCosts = metrics.costInputs.filter { $0.draftDepth > 0 && $0.sampleCount > 0 }
        let costsStayWithinLimit = positiveCosts.allSatisfy {
            $0.decodeRowBucket * ($0.draftDepth + 1) <= maxRectangularTokens
        }
        guard costsStayWithinLimit,
              (metrics.serialVerificationRounds ?? 0) == 0
        else {
            throw MTPBenchmarkError.invalidMetrics(
                "adaptive B=\(batchSize) escaped its automatic rectangular limit")
        }
        if metrics.rounds > 0 {
            // Drafting after tail rows drained inside the cap: every row-round
            // proposes at least one token and is scored by at least one
            // rectangular batch verification (rounds count per-row finalizes;
            // verifier counters count per-batch passes, so equality is NOT
            // the invariant here).
            guard metrics.proposedTokens > 0,
                  (metrics.rectangularVerificationRounds ?? 0) > 0
            else {
                throw MTPBenchmarkError.invalidMetrics(
                    "adaptive B=\(batchSize) drafted without rectangular verification evidence")
            }
            return true
        }
        // Zero rounds: nothing may have been proposed, accepted, committed,
        // or verified. Seed steps alone remain legitimate — they are recorded
        // at step launch, and a seed's own emitted token can terminate the
        // request (production EOS) or the adaptive depth can drop before the
        // planned round ever runs.
        guard metrics.proposedTokens == 0,
              metrics.acceptedDraftTokens == 0,
              metrics.committedTokens == 0,
              (metrics.rectangularVerificationRounds ?? 0) == 0,
              metrics.acceptanceByPosition.allSatisfy({ $0 == 0 }),
              metrics.costInputs.allSatisfy({ $0.draftDepth == 0 })
        else {
            throw MTPBenchmarkError.invalidMetrics(
                "adaptive B=\(batchSize) reported speculative counters without rounds")
        }
        return true
    }

    private static func validateActivation(
        metrics: MTPBenchmarkMetrics,
        mode: MTPBenchmarkMode,
        expectation: MTPBenchmarkMTPExpectation,
        beforeRun: Bool
    ) throws {
        if !mode.requestsMTP, metrics.active {
            throw MTPBenchmarkError.invalidMetrics(
                "target-only baseline unexpectedly reported MTP active\(beforeRun ? " before execution" : "")")
        }
        guard mode.requestsMTP else { return }

        if expectation.expectsInactive {
            guard !metrics.active else {
                throw MTPBenchmarkError.invalidMetrics(
                    "\(mode.label) unexpectedly reported MTP active in expected-inactive mode\(beforeRun ? " before execution" : "")")
            }
            guard expectation.matchesInactiveReason(metrics.inactiveReason) else {
                throw MTPBenchmarkError.invalidMetrics(
                    "\(mode.label) inactive reason did not match the declared exact value or prefix")
            }
            try validateNoSpeculativeWork(
                metrics,
                context: "\(mode.label) expected-inactive metrics\(beforeRun ? " before execution" : "")")
        } else {
            guard metrics.active else {
                let detail = metrics.inactiveReason ?? "missing inactive reason"
                throw MTPBenchmarkError.mtpRequestedButInactive(
                    "\(mode.label) (\(detail))")
            }
            guard metrics.inactiveReason == nil else {
                throw MTPBenchmarkError.invalidMetrics(
                    "\(mode.label) reported active MTP with an inactive reason")
            }
        }
    }

    private static func validateNoSpeculativeWork(
        _ metrics: MTPBenchmarkMetrics,
        context: String
    ) throws {
        guard metrics.rounds == 0,
              metrics.seedRows == 0,
              metrics.proposedTokens == 0,
              metrics.acceptedDraftTokens == 0,
              metrics.committedTokens == 0,
              // Target verification with zero claimed rounds is still
              // speculative work: an engine regression must not verify while
              // reporting inactivity.
              (metrics.rectangularVerificationRounds ?? 0) == 0,
              (metrics.serialVerificationRounds ?? 0) == 0,
              metrics.acceptanceByPosition.isEmpty,
              metrics.conditionalAcceptance.isEmpty,
              metrics.skippedRows.isEmpty,
              metrics.depthSelections.isEmpty,
              metrics.controllerFallbacks.isEmpty,
              metrics.costInputs.isEmpty,
              metrics.totalRoundWallTimeNanos == nil,
              metrics.assistantTimeNanos == nil,
              metrics.targetVerifyTimeNanos == nil
        else {
            throw MTPBenchmarkError.invalidMetrics(
                "\(context) reported speculative work")
        }
    }

    private static func observedBucket(
        _ metrics: MTPBenchmarkMetrics,
        expectedBucket: Int
    ) -> Bool {
        metrics.decodeRowBucket == expectedBucket
            || metrics.costInputs.contains { $0.decodeRowBucket == expectedBucket }
    }

    private static func decodeRowBucket(_ rows: Int) -> Int {
        var bucket = 1
        while bucket < rows { bucket *= 2 }
        return bucket
    }

    private static func runBatch(
        engine: any CBv2Engine,
        prompts: [MTPBenchmarkPrompt],
        batchSize: Int,
        maxTokens: Int,
        stopPolicy: MTPBenchmarkStopPolicy,
        deadlineAt: ContinuousClock.Instant
    ) async throws -> BatchMeasurement {
        let origin = ContinuousClock.now
        var submissions: [(
            row: Int,
            requestID: UInt64,
            prompt: MTPBenchmarkPrompt,
            submittedAtNanoseconds: UInt64,
            stream: AsyncStream<CBv2Event>
        )] = []
        do {
            // Submit every stream before starting any consumer so scheduler
            // membership and decode-row buckets are reproducible.
            for row in 0..<batchSize {
                try requireBeforeDeadline(deadlineAt)
                let prompt = prompts[row % prompts.count]
                let requestID = UInt64(row + 1)
                let submittedAt = ContinuousClock.now
                let stream = try engine.submit(CBv2Request(
                    id: CBv2RequestID(requestID),
                    promptTokens: prompt.tokenIDs,
                    sampling: CBv2SamplingParams(temperature: 0),
                    maxTokens: maxTokens,
                    stopTokens: Set(stopPolicy.stopTokenIDs)))
                submissions.append((
                    row: row,
                    requestID: requestID,
                    prompt: prompt,
                    submittedAtNanoseconds: nanoseconds(submittedAt - origin),
                    stream: stream))
                try requireBeforeDeadline(deadlineAt)
            }
        } catch {
            for submission in submissions {
                engine.cancel(CBv2RequestID(submission.requestID))
            }
            if ContinuousClock.now >= deadlineAt {
                throw MTPBenchmarkError.deadlineExceeded
            }
            throw error
        }

        let requestIDs = submissions.map(\.requestID)
        do {
            let rows = try await withThrowingTaskGroup(
                of: BatchTaskResult.self,
                returning: [MeasuredRow].self
            ) { group in
                for submission in submissions {
                    group.addTask {
                        .row(submission.row, try await consume(
                            stream: submission.stream,
                            row: submission.row,
                            prompt: submission.prompt,
                            submittedAtNanoseconds: submission.submittedAtNanoseconds,
                            origin: origin,
                            maxTokens: maxTokens,
                            stopPolicy: stopPolicy))
                    }
                }
                group.addTask {
                    let now = ContinuousClock.now
                    if now < deadlineAt {
                        try await taskSleep(deadlineAt - now)
                    }
                    for requestID in requestIDs {
                        engine.cancel(CBv2RequestID(requestID))
                    }
                    throw MTPBenchmarkError.deadlineExceeded
                }

                var ordered = Array<MeasuredRow?>(repeating: nil, count: batchSize)
                var received = 0
                while received < batchSize, let result = try await group.next() {
                    switch result {
                    case .row(let row, let value):
                        ordered[row] = value
                        received += 1
                    }
                }
                group.cancelAll()
                return ordered.compactMap { $0 }
            }
            guard rows.count == batchSize else {
                throw MTPBenchmarkError.inconsistentRepetition(
                    "received \(rows.count) rows for B=\(batchSize)")
            }
            return BatchMeasurement(
                rows: rows,
                aggregateDecodeTokensPerSecond:
                    try MTPBenchmarkTiming.aggregateDecodeTokensPerSecond(
                        tokenTimestampsNanoseconds: rows.map(\.tokenTimestampsNanoseconds)))
        } catch {
            for submission in submissions {
                engine.cancel(CBv2RequestID(submission.requestID))
            }
            if ContinuousClock.now >= deadlineAt {
                throw MTPBenchmarkError.deadlineExceeded
            }
            throw error
        }
    }

    private static func consume(
        stream: AsyncStream<CBv2Event>,
        row: Int,
        prompt: MTPBenchmarkPrompt,
        submittedAtNanoseconds: UInt64,
        origin: ContinuousClock.Instant,
        maxTokens: Int,
        stopPolicy: MTPBenchmarkStopPolicy
    ) async throws -> MeasuredRow {
        var tokens: [Int] = []
        var tokenTimestamps: [UInt64] = []
        var finishReason: String?
        for await event in stream {
            switch event {
            case .delta(_, let emitted, _):
                guard finishReason == nil else {
                    throw MTPBenchmarkError.unsuccessfulTerminal(
                        row: row, reason: "delta_after_terminal")
                }
                let timestamp = nanoseconds(ContinuousClock.now - origin)
                tokens.append(contentsOf: emitted)
                tokenTimestamps.append(
                    contentsOf: repeatElement(timestamp, count: emitted.count))
            case .finished(let reason, let usage):
                guard finishReason == nil else {
                    throw MTPBenchmarkError.unsuccessfulTerminal(
                        row: row, reason: "duplicate_terminal")
                }
                guard usage.completionTokens == tokens.count else {
                    throw MTPBenchmarkError.unsuccessfulTerminal(
                        row: row, reason: "usage_count_mismatch")
                }
                switch reason {
                case .cancelled:
                    throw MTPBenchmarkError.unsuccessfulTerminal(
                        row: row, reason: "cancelled")
                case .error:
                    throw MTPBenchmarkError.unsuccessfulTerminal(
                        row: row, reason: "engine_error")
                case .stop:
                    finishReason = "stop"
                case .length:
                    finishReason = "length"
                }
            }
        }
        guard let finishReason else {
            throw MTPBenchmarkError.missingTerminalEvent(row: row)
        }
        guard !tokens.isEmpty else { throw MTPBenchmarkError.emptyTokenStream(row: row) }
        switch stopPolicy.kind {
        case .rawFixedLengthNoStop:
            guard finishReason == "length", tokens.count == maxTokens else {
                throw MTPBenchmarkError.unexpectedTerminal(
                    row: row,
                    condition: "raw fixed-length completion")
            }
        case .productionTargetEOS:
            guard finishReason == "stop" || finishReason == "length" else {
                throw MTPBenchmarkError.unexpectedTerminal(
                    row: row,
                    condition: "production terminal reason")
            }
            // No terminal may exceed the requested budget: an engine that
            // overshoots maxTokens before its EOS violates the OpenAI-visible
            // limit even when both sessions overshoot identically.
            guard tokens.count <= maxTokens else {
                throw MTPBenchmarkError.unexpectedTerminal(
                    row: row,
                    condition: "production terminal within maxTokens")
            }
            if finishReason == "stop" {
                guard let finalToken = tokens.last,
                      stopPolicy.stopTokenIDs.contains(finalToken)
                else {
                    throw MTPBenchmarkError.unexpectedTerminal(
                        row: row,
                        condition: "production stop membership")
                }
            }
            // A "length" terminal certifies the decode ran to the token budget.
            // Fewer tokens means the engine truncated early; rejecting it here
            // keeps identical premature truncation in both sessions from
            // passing token parity and the gates.
            if finishReason == "length" {
                guard tokens.count == maxTokens else {
                    throw MTPBenchmarkError.unexpectedTerminal(
                        row: row,
                        condition: "production length terminal reached maxTokens")
                }
            }
        }
        let timing = try MTPBenchmarkTiming.stream(
            submittedAtNanoseconds: submittedAtNanoseconds,
            tokenTimestampsNanoseconds: tokenTimestamps)
        return MeasuredRow(
            promptName: prompt.name,
            tokenIDs: tokens,
            tokenTimestampsNanoseconds: tokenTimestamps,
            timing: timing,
            finishReason: finishReason)
    }

    private static func validateRepetitionConsistency(
        _ samples: [CaseSample],
        key: CaseKey
    ) throws {
        guard let first = samples.first else {
            throw MTPBenchmarkError.invalidMeasurementRepetitions(0)
        }
        let expected = first.batch.rows.map { ($0.promptName, $0.tokenIDs, $0.finishReason) }
        for sample in samples.dropFirst() {
            let actual = sample.batch.rows.map { ($0.promptName, $0.tokenIDs, $0.finishReason) }
            guard actual.elementsEqual(expected, by: {
                $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
            }) else {
                throw MTPBenchmarkError.inconsistentRepetition(
                    "\(key.mode.label), B=\(key.batchSize) changed tokens, prompts, or terminal reason")
            }
        }
    }

    private static func aggregate(
        samples: [CaseSample],
        key: CaseKey,
        performanceEligible: Bool,
        tokenEvidenceSalt: Data
    ) -> MTPBenchmarkCaseResult {
        let sortedSamples = samples.sorted {
            $0.batch.aggregateDecodeTokensPerSecond < $1.batch.aggregateDecodeTokensPerSecond
        }
        let representative = sortedSamples[(sortedSamples.count - 1) / 2]
        let rowCount = representative.batch.rows.count
        let rows = (0..<rowCount).map { row -> MTPBenchmarkRowResult in
            let source = representative.batch.rows[row]
            return MTPBenchmarkRowResult(
                promptName: source.promptName,
                tokenCount: source.tokenIDs.count,
                opaqueTokenDigest: MTPBenchmarkDigest.opaqueTokenDigest(
                    tokenIDs: source.tokenIDs,
                    salt: tokenEvidenceSalt),
                timeToFirstTokenMs: performanceEligible
                    ? median(samples.map { $0.batch.rows[row].timing.timeToFirstTokenMs })
                    : nil,
                interTokenLatencyMs: performanceEligible
                    ? median(samples.map { $0.batch.rows[row].timing.interTokenLatencyMs })
                    : nil,
                decodeTokensPerSecond: performanceEligible
                    ? median(samples.map { $0.batch.rows[row].timing.decodeTokensPerSecond })
                    : nil,
                lastTokenLatencyMs: performanceEligible
                    ? median(samples.map { $0.batch.rows[row].timing.lastTokenLatencyMs })
                    : nil,
                finishReason: source.finishReason)
        }
        return MTPBenchmarkCaseResult(
            mode: key.mode,
            batchSize: key.batchSize,
            measurementRepetitions: samples.count,
            medianAggregateDecodeTokensPerSecond: performanceEligible
                ? median(samples.map { $0.batch.aggregateDecodeTokensPerSecond })
                : nil,
            tokenParity: true,
            parityMismatchRows: [],
            rows: rows,
            metrics: representative.metrics)
    }

    private static func parityMismatches(
        baseline: [[Int]], candidate: [[Int]]
    ) -> [Int] {
        let count = max(baseline.count, candidate.count)
        return (0..<count).filter { row in
            guard row < baseline.count, row < candidate.count else { return true }
            return baseline[row] != candidate[row]
        }
    }

    private static func validateArtifactBoundary(
        _ artifact: MTPBenchmarkArtifactFacts,
        label: String
    ) throws {
        guard artifact.hasVerifiableProvenance else { return }
        try MTPBenchmarkModelFacts.validateUnchanged(artifact, label: label)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func requireBeforeDeadline(
        _ deadlineAt: ContinuousClock.Instant
    ) throws {
        guard ContinuousClock.now < deadlineAt else {
            throw MTPBenchmarkError.deadlineExceeded
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanos = UInt64(components.attoseconds / 1_000_000_000)
        return seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue &+ nanos
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9e3779b97f4a7c15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

private extension Array {
    mutating func seededShuffle(using generator: inout SeededGenerator) {
        guard count > 1 else { return }
        for index in stride(from: count - 1, through: 1, by: -1) {
            let other = Int(generator.next() % UInt64(index + 1))
            if index != other { swapAt(index, other) }
        }
    }
}
