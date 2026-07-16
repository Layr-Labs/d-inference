import Foundation
import MLXLMCommon
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("MTP benchmark report and matrix")
struct MTPBenchmarkTests {
    @Test("standard matrix is baseline, fixed L=1...8, adaptive")
    func standardMatrix() throws {
        let modes = MTPBenchmarkRunner.standardModes
        #expect(modes.count == 10)
        #expect(modes.first == .targetOnly)
        #expect(modes.last == .adaptive)
        #expect(modes.dropFirst().dropLast().map(\.verificationWidth) == (1...8).map(Optional.some))
        #expect(modes.dropFirst().dropLast().map(\.fixedDraftTokens) == (0...7).map(Optional.some))
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkMode.fixed(verificationWidth: 9)
        }
    }

    @Test("engine metrics preserve the target verification mode")
    func verificationModeProjection() {
        var engineMetrics = CBv2MTPMetrics()
        engineMetrics.verificationMode = .rectangular
        engineMetrics.maxAutomaticRectangularTokens = 8
        engineMetrics.rectangularVerificationRounds = 3
        engineMetrics.serialVerificationRounds = 1
        let projected = MTPBenchmarkMetrics(engineMetrics: engineMetrics)
        #expect(projected.verificationMode == "rectangular")
        #expect(projected.maxAutomaticRectangularTokens == 8)
        #expect(projected.rectangularVerificationRounds == 3)
        #expect(projected.serialVerificationRounds == 1)
    }

    @Test("artifact inspection records immutable config and shard provenance")
    func artifactInspection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(String(repeating: "a", count: 40))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data(#"{"model_type":"gemma4_assistant","architectures":["Gemma4AssistantForCausalLM"],"dtype":"bfloat16","quantization":{"bits":4,"group_size":64,"mode":"affine","layer_overrides":{"head":{"bits":8}}}}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 17)
            .write(to: root.appendingPathComponent("model.safetensors"))

        let facts = try MTPBenchmarkModelFacts.inspect(modelID: "assistant", directory: root)
        #expect(facts.revision == String(repeating: "a", count: 40))
        #expect(facts.modelType == "gemma4_assistant")
        #expect(facts.quantization?.bits == 4)
        #expect(facts.quantization?.groupSize == 64)
        #expect(facts.quantization?.perLayerOverridesByBits["8"] == 1)
        #expect(facts.weightFileCount == 1)
        #expect(facts.weightBytes == 17)
        #expect(facts.configSizeBytes > 0)
        #expect(facts.artifactBytes == facts.configSizeBytes + 17)
        #expect(facts.configSHA256.count == 64)
        #expect(facts.weightFiles[0].identityKind == .sha256)
        #expect(facts.weightFiles[0].contentIdentity.count == 64)
        #expect(facts.artifactFingerprint.count == 64)
        #expect(facts.hasVerifiableProvenance)
        try MTPBenchmarkModelFacts.validateUnchanged(facts, label: "assistant")
    }

    @Test("Hugging Face blob OIDs avoid weight hashing and bind model ID")
    func huggingFaceBlobIdentityAndDrift() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-hf-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("models--example--assistant")
        let revision = String(repeating: "a", count: 40)
        let snapshot = repository.appendingPathComponent("snapshots/\(revision)")
        let blobs = repository.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"model_type":"gemma4_assistant"}"#.utf8)
            .write(to: snapshot.appendingPathComponent("config.json"))
        let firstOID = String(repeating: "b", count: 64)
        let secondOID = String(repeating: "c", count: 64)
        try Data(repeating: 1, count: 11).write(to: blobs.appendingPathComponent(firstOID))
        try Data(repeating: 2, count: 11).write(to: blobs.appendingPathComponent(secondOID))
        let weight = snapshot.appendingPathComponent("model.safetensors")
        try FileManager.default.createSymbolicLink(
            at: weight, withDestinationURL: blobs.appendingPathComponent(firstOID))

        let facts = try MTPBenchmarkModelFacts.inspect(modelID: nil, directory: snapshot)
        #expect(facts.modelID == "example/assistant")
        #expect(facts.weightFiles[0].identityKind == .hfBlobSHA256)
        #expect(facts.weightFiles[0].contentIdentity == firstOID)
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkModelFacts.inspect(modelID: "other/assistant", directory: snapshot)
        }

        try FileManager.default.removeItem(at: weight)
        try FileManager.default.createSymbolicLink(
            at: weight, withDestinationURL: blobs.appendingPathComponent(secondOID))
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkModelFacts.validateUnchanged(facts, label: "assistant")
        }
    }

    @Test("benchmark assistant sizing stays identical to production")
    func assistantResidentSizingDrift() {
        for bytes: UInt64 in [0, 1, 17, 4_096, 7_999_999_999] {
            #expect(MTPBenchmarkSizing.assistantResidentBytes(artifactBytes: bytes)
                == SpecDecLimits.residentEstimate(artifactBytes: bytes))
        }

        let artifact = MTPBenchmarkArtifactFacts(
            modelID: "assistant", resolvedPath: "/tmp/assistant", revision: "local",
            modelType: "gemma4_assistant", architecture: "Gemma4AssistantForCausalLM",
            dtype: "bfloat16", quantization: nil,
            weightFiles: [.init(name: "model.safetensors", sizeBytes: 100)])
        #expect(
            MTPBenchmarkSizing.totalResidentWeightBytes(
                targetWeightBytes: 1_000, assistant: artifact)
                == 1_000 + SpecDecLimits.residentEstimate(artifactBytes: 100))
        #expect(
            MTPBenchmarkSizing.totalResidentWeightBytes(
                targetWeightBytes: Int.max, assistant: artifact)
                == UInt64(Int.max) + SpecDecLimits.residentEstimate(artifactBytes: 100))
    }

    @Test("report JSON preserves parity and exposed metrics")
    func reportJSON() throws {
        let artifact = MTPBenchmarkArtifactFacts(
            modelID: "target",
            resolvedPath: "/tmp/target",
            revision: String(repeating: "b", count: 40),
            modelType: "gemma4",
            architecture: "Gemma4ForConditionalGeneration",
            dtype: "bfloat16",
            quantization: .init(bits: 4, groupSize: 64, mode: "affine"),
            weightFiles: [.init(name: "model.safetensors", sizeBytes: 42)])
        let mode = try MTPBenchmarkMode.fixed(verificationWidth: 3)
        let startedAt = Date()
        let report = MTPBenchmarkReport(
            runFingerprint: "unit-test-run",
            purpose: .productionPerformance,
            stopPolicy: .production(tokenIDs: [1, 2]),
            startedAt: startedAt,
            completedAt: startedAt,
            complete: true,
            expectedCaseCount: 1,
            target: artifact,
            assistant: artifact,
            hardware: .init(
                 machineModel: "Mac", chipName: "Apple M4 Max", chipFamily: "m4",
                 chipTier: "max", memoryGB: 128, gpuCores: 40, memoryBandwidthGBps: 546),
            maxTokensPerRow: 32,
            warmupIterations: 1,
            measurementRepetitions: 3,
            modeOrderSeed: 42,
            coverage: .shortContextMatrix(
                target: artifact, assistant: artifact, purpose: .productionPerformance),
            elapsedMs: 100,
            cases: [.init(
                mode: mode,
                batchSize: 1,
                measurementRepetitions: 3,
                medianAggregateDecodeTokensPerSecond: 50,
                tokenParity: true,
                parityMismatchRows: [],
                rows: [.init(
                    promptName: "math", tokenCount: 2,
                    opaqueTokenDigest: String(repeating: "c", count: 64),
                    timeToFirstTokenMs: 10,
                    interTokenLatencyMs: 20, decodeTokensPerSecond: 50,
                    lastTokenLatencyMs: 30, finishReason: "length")],
                metrics: .init(
                    active: true, selectedDepth: 2, decodeRowBucket: 1,
                    rounds: 1, proposedTokens: 2,
                    acceptedDraftTokens: 1, committedTokens: 2,
                    acceptanceByPosition: [1, 0], conditionalAcceptance: [1, 0],
                    totalRoundWallTimeNanos: 1_000))])

        let data = try report.jsonData()
        let decoded = try JSONDecoder.withISO8601.decode(MTPBenchmarkReport.self, from: data)
        #expect(decoded.schemaVersion == MTPBenchmarkReport.currentSchemaVersion)
        #expect(decoded.buildConfiguration == .current)
        #expect(decoded.mtpExpectation == .active)
        #expect(decoded.cases.first?.tokenParity == true)
        #expect(decoded.cases.first?.metrics.selectedDepth == 2)
        #expect(decoded.cases.first?.metrics.totalRoundWallTimeNanos == 1_000)
        #expect(decoded.runFingerprint == MTPBenchmarkReport.buildBoundFingerprint(
            "unit-test-run", buildConfiguration: .current))
        #expect(decoded.complete)
        #expect(decoded.stopPolicy.kind == .productionTargetEOS)
        #expect(decoded.stopPolicy.configuredTokenCount == 2)
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(findKeys(in: object, matching: ["tokenIDs"]).isEmpty)
    }

    @Test("expected-inactive metrics require the declared reason and zero work")
    func expectedInactiveMetricsValidation() throws {
        let mode = try MTPBenchmarkMode.fixed(verificationWidth: 3)
        let reason = "rectangular MTP verification is disabled on Apple M5 Max: target-only and [B, 1+k] target argmax parity is not certified"
        let exactExpectation = MTPBenchmarkMTPExpectation.expectedInactive(
            allowedReasonValues: [reason])

        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(active: false, inactiveReason: reason),
                mode: mode,
                batchSize: 2,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }
        for invalid in [
            MTPBenchmarkMetrics(active: false),
            MTPBenchmarkMetrics(active: false, inactiveReason: "configuration disabled"),
            MTPBenchmarkMetrics(active: false, inactiveReason: reason, rounds: 1),
            // Target verification with zero claimed rounds is still work.
            MTPBenchmarkMetrics(
                active: false, rectangularVerificationRounds: 1, inactiveReason: reason),
            MTPBenchmarkMetrics(
                active: false, serialVerificationRounds: 1, inactiveReason: reason),
        ] {
            #expect(throws: MTPBenchmarkError.self) {
                try MTPBenchmarkRunner.validateMetrics(
                    invalid,
                    mode: mode,
                    batchSize: 2,
                    adaptiveDraftingExpected: true,
                    allowedSkipReasons: [],
                    expectation: exactExpectation)
            }
        }
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(active: true),
                mode: mode,
                batchSize: 2,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [],
                expectation: exactExpectation)
        }

        try MTPBenchmarkRunner.validateMetrics(
            MTPBenchmarkMetrics(active: false, inactiveReason: reason),
            mode: mode,
            batchSize: 2,
            adaptiveDraftingExpected: true,
            allowedSkipReasons: [],
            expectation: exactExpectation)
        #expect(MTPBenchmarkMTPExpectation.legacyM5HardwareSafetyGate
            .matchesInactiveReason(reason))
    }

    @Test("expected-inactive raw report preserves reason without raw tokens or timing")
    func expectedInactiveReportSerialization() throws {
        let artifact = testArtifact()
        let reason = "rectangular MTP verification is disabled on Apple M5 Max: target-only and [B, 1+k] target argmax parity is not certified"
        let expectation = MTPBenchmarkMTPExpectation.legacyM5HardwareSafetyGate
        let report = MTPBenchmarkReport(
            runFingerprint: "inactive-unit-test",
            purpose: .rawParityStress,
            mtpExpectation: expectation,
            stopPolicy: .rawFixedLength,
            startedAt: Date(),
            completedAt: Date(),
            complete: true,
            expectedCaseCount: 1,
            target: artifact,
            assistant: artifact,
            hardware: testHardware(),
            maxTokensPerRow: 1,
            warmupIterations: 0,
            measurementRepetitions: 1,
            modeOrderSeed: 1,
            coverage: .shortContextMatrix(target: artifact, assistant: artifact),
            elapsedMs: 10,
            cases: [.init(
                mode: .adaptive,
                batchSize: 1,
                measurementRepetitions: 1,
                medianAggregateDecodeTokensPerSecond: 10,
                tokenParity: true,
                parityMismatchRows: [],
                rows: [.init(
                    promptName: "p",
                    tokenCount: 1,
                    opaqueTokenDigest: String(repeating: "e", count: 64),
                    timeToFirstTokenMs: 1,
                    interTokenLatencyMs: 2,
                    decodeTokensPerSecond: 3,
                    lastTokenLatencyMs: 4,
                    finishReason: "length")],
                metrics: .init(active: false, inactiveReason: reason))])

        let data = try report.jsonData()
        let decoded = try JSONDecoder.withISO8601.decode(MTPBenchmarkReport.self, from: data)
        #expect(decoded.mtpExpectation == expectation)
        #expect(decoded.cases.first?.metrics.inactiveReason == reason)
        #expect(decoded.runFingerprint.contains(":expected_inactive:"))
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(findKeys(in: object, matching: ["inactiveReason"]) == ["inactiveReason"])
        #expect(findKeys(in: object, matching: ["tokenIDs"]).isEmpty)
        #expect(findKeys(in: object, matching: [
            "elapsedMs",
            "medianAggregateDecodeTokensPerSecond",
            "timeToFirstTokenMs",
            "interTokenLatencyMs",
            "decodeTokensPerSecond",
            "lastTokenLatencyMs",
            "totalRoundWallTimeNanos",
        ]).isEmpty)
    }

    @Test("stream and aggregate timing use token timestamps and N-1 intervals")
    func deterministicTokenTiming() throws {
        let stream = try MTPBenchmarkTiming.stream(
            submittedAtNanoseconds: 1_000_000_000,
            tokenTimestampsNanoseconds: [
                1_100_000_000,
                1_200_000_000,
                1_400_000_000,
            ])
        #expect(stream.timeToFirstTokenMs == 100)
        #expect(stream.interTokenLatencyMs == 150)
        #expect(abs(stream.decodeTokensPerSecond - (2.0 / 0.3)) < 0.000_001)
        #expect(stream.lastTokenLatencyMs == 400)

        let aggregate = try MTPBenchmarkTiming.aggregateDecodeTokensPerSecond(
            tokenTimestampsNanoseconds: [
                [100_000_000, 200_000_000, 300_000_000],
                [150_000_000, 250_000_000],
            ])
        #expect(abs(aggregate - 15) < 0.000_001)
    }

    @Test("fixed metrics prove requested depth and actual row bucket")
    func fixedMetricsValidation() throws {
        let mode = try MTPBenchmarkMode.fixed(verificationWidth: 3)
        let metrics = MTPBenchmarkMetrics(
            active: true,
            selectedDepth: 1,
            decodeRowBucket: 2,
            rounds: 8,
            proposedTokens: 16,
            skippedRows: [:],
            depthSelections: ["1": 1, "2": 8],
            costInputs: [.init(
                decodeRowBucket: 2,
                draftDepth: 2,
                sampleCount: 8,
                ewmaRoundWallTimeNanos: 10,
                totalRoundWallTimeNanos: 80)])
        try MTPBenchmarkRunner.validateMetrics(
            metrics,
            mode: mode,
            batchSize: 2,
            adaptiveDraftingExpected: true,
            allowedSkipReasons: [])

        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    selectedDepth: 2,
                    decodeRowBucket: 2,
                    rounds: 8,
                    proposedTokens: 16,
                    skippedRows: ["planner_clamp": 1],
                    depthSelections: ["2": 8],
                    costInputs: metrics.costInputs),
                mode: mode,
                batchSize: 2,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }
    }

    @Test("automatic fixed depth accepts certified target-only fallback")
    func automaticFixedDepthFallbackValidation() throws {
        let mode = try MTPBenchmarkMode.fixed(verificationWidth: 2)
        let fallback = MTPBenchmarkMetrics(
            active: true,
            verificationMode: "automatic",
            maxAutomaticRectangularTokens: 8,
            rectangularVerificationRounds: 0,
            serialVerificationRounds: 0,
            selectedDepth: 0,
            decodeRowBucket: 8,
            depthSelections: ["0": 4],
            controllerFallbacks: ["automatic_rectangular_limit": 4],
            totalRoundWallTimeNanos: 0)

        try MTPBenchmarkRunner.validateMetrics(
            fallback,
            mode: mode,
            batchSize: 8,
            adaptiveDraftingExpected: true,
            allowedSkipReasons: [])

        let safeAfterBatchShrink = MTPBenchmarkMetrics(
            active: true,
            verificationMode: "automatic",
            maxAutomaticRectangularTokens: 8,
            rectangularVerificationRounds: 2,
            serialVerificationRounds: 0,
            selectedDepth: 1,
            decodeRowBucket: 4,
            rounds: 2,
            proposedTokens: 8,
            depthSelections: ["0": 2, "1": 2],
            controllerFallbacks: ["automatic_rectangular_limit": 2],
            costInputs: [.init(
                decodeRowBucket: 4,
                draftDepth: 1,
                sampleCount: 2)])
        try MTPBenchmarkRunner.validateMetrics(
            safeAfterBatchShrink,
            mode: mode,
            batchSize: 8,
            adaptiveDraftingExpected: true,
            allowedSkipReasons: [])

        // Regression: a requested depth clamped to a SMALLER POSITIVE depth
        // records only positive selections. The validator must not demand
        // depth-zero selections in that case (found by the real M4 matrix at
        // B=4 with fixed L=3 clamping to k=1).
        // No cost inputs on purpose: the controller refuses attribution when
        // the finalized depth differs from its requested fixed depth.
        let positiveClamp = MTPBenchmarkMetrics(
            active: true,
            verificationMode: "automatic",
            maxAutomaticRectangularTokens: 8,
            rectangularVerificationRounds: 6,
            serialVerificationRounds: 0,
            selectedDepth: 1,
            decodeRowBucket: 4,
            rounds: 6,
            proposedTokens: 6,
            depthSelections: ["1": 6],
            controllerFallbacks: ["automatic_rectangular_limit": 6])
        try MTPBenchmarkRunner.validateMetrics(
            positiveClamp,
            mode: try MTPBenchmarkMode.fixed(verificationWidth: 3),
            batchSize: 4,
            adaptiveDraftingExpected: true,
            allowedSkipReasons: [])

        // A positive cost input whose bucket * (depth + 1) exceeds the cap
        // proves work escaped the envelope and must fail even with the
        // fallback reason recorded.
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    verificationMode: "automatic",
                    maxAutomaticRectangularTokens: 8,
                    rectangularVerificationRounds: 2,
                    serialVerificationRounds: 0,
                    selectedDepth: 1,
                    decodeRowBucket: 8,
                    rounds: 2,
                    proposedTokens: 2,
                    depthSelections: ["1": 2],
                    controllerFallbacks: ["automatic_rectangular_limit": 2],
                    costInputs: [.init(
                        decodeRowBucket: 8,
                        draftDepth: 1,
                        sampleCount: 2)]),
                mode: mode,
                batchSize: 8,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }

        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    verificationMode: "automatic",
                    maxAutomaticRectangularTokens: 8,
                    selectedDepth: 0,
                    decodeRowBucket: 4,
                    depthSelections: ["0": 4],
                    controllerFallbacks: ["automatic_rectangular_limit": 4]),
                mode: mode,
                batchSize: 4,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }
    }

    @Test("adaptive accepts certified within-cap behavior when the cap forbids drafting")
    func adaptiveAutomaticCapValidation() throws {
        // B=8 with cap 8: even depth one exceeds the cap, so zero drafting
        // with only depth-zero selections is the correct outcome.
        try MTPBenchmarkRunner.validateMetrics(
            MTPBenchmarkMetrics(
                active: true,
                verificationMode: "automatic",
                maxAutomaticRectangularTokens: 8,
                rectangularVerificationRounds: 0,
                serialVerificationRounds: 0,
                selectedDepth: 0,
                decodeRowBucket: 8,
                depthSelections: ["0": 4],
                controllerFallbacks: ["warmup": 4]),
            mode: .adaptive,
            batchSize: 8,
            adaptiveDraftingExpected: true,
            allowedSkipReasons: [])

        // Seed steps alone are legitimate: they are recorded at step launch
        // and the row can terminate before its round runs.
        try MTPBenchmarkRunner.validateMetrics(
            MTPBenchmarkMetrics(
                active: true,
                verificationMode: "automatic",
                maxAutomaticRectangularTokens: 8,
                rectangularVerificationRounds: 0,
                serialVerificationRounds: 0,
                selectedDepth: 0,
                decodeRowBucket: 8,
                seedRows: 2,
                depthSelections: ["0": 3, "1": 1],
                controllerFallbacks: ["warmup": 4]),
            mode: .adaptive,
            batchSize: 8,
            adaptiveDraftingExpected: true,
            allowedSkipReasons: [])

        // Zero rounds with nonzero draft counters must fail.
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    verificationMode: "automatic",
                    maxAutomaticRectangularTokens: 8,
                    rectangularVerificationRounds: 0,
                    serialVerificationRounds: 0,
                    selectedDepth: 0,
                    decodeRowBucket: 8,
                    proposedTokens: 3,
                    depthSelections: ["0": 4],
                    controllerFallbacks: ["warmup": 4]),
                mode: .adaptive,
                batchSize: 8,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }

        // Positive rounds without any rectangular verification evidence must
        // fail even when cost inputs are empty.
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    verificationMode: "automatic",
                    maxAutomaticRectangularTokens: 8,
                    rectangularVerificationRounds: 0,
                    serialVerificationRounds: 0,
                    selectedDepth: 1,
                    decodeRowBucket: 4,
                    rounds: 2,
                    proposedTokens: 4,
                    depthSelections: ["0": 2, "1": 2],
                    controllerFallbacks: ["automatic_rectangular_limit": 2]),
                mode: .adaptive,
                batchSize: 8,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }

        // Late-drain drafting at a smaller bucket stays acceptable only while
        // rectangular and inside the cap; serial rounds must fail.
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    verificationMode: "automatic",
                    maxAutomaticRectangularTokens: 8,
                    rectangularVerificationRounds: 1,
                    serialVerificationRounds: 1,
                    selectedDepth: 1,
                    decodeRowBucket: 4,
                    rounds: 2,
                    proposedTokens: 2,
                    depthSelections: ["0": 2, "1": 2],
                    controllerFallbacks: ["automatic_rectangular_limit": 2],
                    costInputs: [.init(
                        decodeRowBucket: 4,
                        draftDepth: 1,
                        sampleCount: 2)]),
                mode: .adaptive,
                batchSize: 8,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }
    }

    @Test("production evidence pins active cases to the automatic verifier")
    func productionRequiresAutomaticVerifier() throws {
        let mode = try MTPBenchmarkMode.fixed(verificationWidth: 1)
        let serialMetrics = MTPBenchmarkMetrics(
            active: true,
            verificationMode: "serial_target",
            serialVerificationRounds: 3,
            selectedDepth: 0,
            decodeRowBucket: 1,
            depthSelections: ["0": 1])
        // Raw parity remains mode-agnostic (the serial/rectangular
        // diagnostic vehicle).
        try MTPBenchmarkRunner.validateMetrics(
            serialMetrics,
            mode: mode,
            batchSize: 1,
            adaptiveDraftingExpected: false,
            allowedSkipReasons: [])
        // Production evidence must reject the retired serial verifier.
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                serialMetrics,
                mode: mode,
                batchSize: 1,
                adaptiveDraftingExpected: false,
                allowedSkipReasons: [],
                requireAutomaticVerification: true)
        }
    }

    @Test("adaptive mode must actually draft where requested")
    func adaptiveMustDraft() {
        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    selectedDepth: 0,
                    decodeRowBucket: 1,
                    depthSelections: ["0": 2],
                    costInputs: [.init(
                        decodeRowBucket: 1,
                        draftDepth: 0,
                        sampleCount: 2,
                        ewmaRoundWallTimeNanos: 10,
                        totalRoundWallTimeNanos: 20)]),
                mode: .adaptive,
                batchSize: 1,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }

        #expect(throws: MTPBenchmarkError.self) {
            try MTPBenchmarkRunner.validateMetrics(
                MTPBenchmarkMetrics(
                    active: true,
                    selectedDepth: 2,
                    decodeRowBucket: 4,
                    rounds: 2,
                    proposedTokens: 4,
                    depthSelections: ["2": 2],
                    costInputs: [.init(
                        decodeRowBucket: 2,
                        draftDepth: 2,
                        sampleCount: 2,
                        ewmaRoundWallTimeNanos: 10,
                        totalRoundWallTimeNanos: 20)]),
                mode: .adaptive,
                batchSize: 4,
                adaptiveDraftingExpected: true,
                allowedSkipReasons: [])
        }
    }

    @Test("error terminal fails the benchmark run")
    func errorTerminalFailsRun() async throws {
        let artifact = testArtifact()
        let engine = TerminalErrorEngine()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: engine) { .inactive }
        }
        do {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1, 2])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: 1,
                    purpose: .rawParityStress,
                    stopPolicy: .rawFixedLength,
                    deadline: .seconds(60)),
                sessions: sessions)
            Issue.record("benchmark accepted an error terminal")
        } catch let error as MTPBenchmarkError {
            #expect(error.description.contains("engine_error"))
            #expect(!error.description.contains("7"))
        }
    }

    @Test("raw parity checkpoint is complete and contains no performance fields")
    func rawParityRedactsPerformance() async throws {
        let artifact = testArtifact()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try MTPBenchmarkReportDestination.open(
            directoryURL: directory,
            fileName: "report.json")
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: SuccessfulLengthEngine()) { .inactive }
        }
        let report = try await MTPBenchmarkRunner.run(
            target: artifact,
            assistant: artifact,
            hardware: testHardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: [.init(name: "prompt", tokenIDs: [1, 2])],
                batchSizes: [1],
                modes: [.targetOnly],
                maxTokensPerRow: 1,
                purpose: .rawParityStress,
                stopPolicy: .rawFixedLength,
                checkpointDestination: destination,
                deadline: .seconds(60)),
            sessions: sessions)
        #expect(report.complete)
        #expect(report.cases.first?.medianAggregateDecodeTokensPerSecond == nil)
        #expect(report.cases.first?.rows.first?.timeToFirstTokenMs == nil)
        #expect(report.cases.first?.rows.first?.decodeTokensPerSecond == nil)
        #expect(report.cases.first?.rows.first?.tokenCount == 1)
        #expect(report.cases.first?.rows.first?.opaqueTokenDigest.count == 64)
        #expect(report.elapsedMs == nil)

        let persisted = try JSONDecoder.withISO8601.decode(
            MTPBenchmarkReport.self, from: Data(contentsOf: destination.url))
        #expect(persisted.complete)
        #expect(persisted.cases.count == persisted.expectedCaseCount)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.url))
        #expect(findKeys(in: object, matching: ["tokenIDs"]).isEmpty)
    }

    @Test("production performance retains corrected token timing fields")
    func productionPerformanceTimingFields() async throws {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: SuccessfulLengthEngine()) { .inactive }
        }
        #if DEBUG
        await #expect(throws: MTPBenchmarkError.self) {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1, 2])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: 1,
                    purpose: .productionPerformance,
                    stopPolicy: .production(tokenIDs: [9]),
                    measurementRepetitions: 2,
                    deadline: .seconds(60)),
                sessions: sessions)
        }
        #else
        let report = try await MTPBenchmarkRunner.run(
            target: artifact,
            assistant: artifact,
            hardware: testHardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: [.init(name: "prompt", tokenIDs: [1, 2])],
                batchSizes: [1],
                modes: [.targetOnly],
                maxTokensPerRow: 1,
                purpose: .productionPerformance,
                stopPolicy: .production(tokenIDs: [9]),
                measurementRepetitions: 2,
                deadline: .seconds(60)),
            sessions: sessions)
        #expect(report.cases.first?.medianAggregateDecodeTokensPerSecond == 0)
        #expect(report.cases.first?.rows.first?.timeToFirstTokenMs != nil)
        #expect(report.cases.first?.rows.first?.decodeTokensPerSecond == 0)
        #expect(report.elapsedMs != nil)
        #endif
    }

    @Test("production performance rejects expected-inactive certification")
    func productionPerformanceRejectsExpectedInactive() async {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: SuccessfulLengthEngine()) { .inactive }
        }
        await #expect(throws: MTPBenchmarkError.self) {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: 1,
                    purpose: .productionPerformance,
                    mtpExpectation: .legacyM5HardwareSafetyGate,
                    stopPolicy: .production(tokenIDs: [9]),
                    deadline: .seconds(60)),
                sessions: sessions)
        }
    }

    @Test("all non-performance reports recursively omit performance keys")
    func nonPerformanceReportsRecursivelyRedactPerformance() throws {
        let artifact = testArtifact()
        let performanceKeys: Set<String> = [
            "elapsedMs",
            "medianAggregateDecodeTokensPerSecond",
            "timeToFirstTokenMs",
            "interTokenLatencyMs",
            "decodeTokensPerSecond",
            "lastTokenLatencyMs",
            "ewmaRoundWallTimeNanos",
            "totalRoundWallTimeNanos",
            "assistantTimeNanos",
            "targetVerifyTimeNanos",
        ]
        for purpose in [MTPBenchmarkPurpose.rawParityStress, .productionCorrectness] {
            let stopPolicy: MTPBenchmarkStopPolicy = purpose == .rawParityStress
                ? .rawFixedLength
                : .production(tokenIDs: [9])
            let report = MTPBenchmarkReport(
                runFingerprint: "redaction-\(purpose.rawValue)",
                purpose: purpose,
                stopPolicy: stopPolicy,
                startedAt: Date(),
                completedAt: Date(),
                complete: true,
                expectedCaseCount: 1,
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                maxTokensPerRow: 1,
                warmupIterations: 0,
                measurementRepetitions: 1,
                modeOrderSeed: 1,
                coverage: .shortContextMatrix(target: artifact, assistant: artifact),
                elapsedMs: 123,
                cases: [.init(
                    mode: .adaptive,
                    batchSize: 1,
                    measurementRepetitions: 1,
                    medianAggregateDecodeTokensPerSecond: 50,
                    tokenParity: true,
                    parityMismatchRows: [],
                    rows: [.init(
                        promptName: "p",
                        tokenCount: 1,
                        opaqueTokenDigest: String(repeating: "d", count: 64),
                        timeToFirstTokenMs: 1,
                        interTokenLatencyMs: 2,
                        decodeTokensPerSecond: 3,
                        lastTokenLatencyMs: 4,
                        finishReason: "stop")],
                    metrics: .init(
                        active: true,
                        selectedDepth: 1,
                        decodeRowBucket: 1,
                        rounds: 1,
                        proposedTokens: 1,
                        costInputs: [.init(
                            decodeRowBucket: 1,
                            draftDepth: 1,
                            sampleCount: 1,
                            ewmaRoundWallTimeNanos: 5,
                            totalRoundWallTimeNanos: 6)],
                        totalRoundWallTimeNanos: 7,
                        assistantTimeNanos: 8,
                        targetVerifyTimeNanos: 9))])
            let object = try JSONSerialization.jsonObject(with: report.jsonData())
            #expect(findKeys(in: object, matching: performanceKeys).isEmpty)
            #expect(findKeys(in: object, matching: ["tokenIDs"]).isEmpty)
        }
    }

    @Test("production policy includes tokenizer and extra EOS absent from base")
    func productionStopPolicyUsesServingUnion() async throws {
        let policy = MTPBenchmarkProductionPolicy.stopTokenIDs(
            modelID: "example/gemma4",
            modelType: "gemma4",
            baseConfigTokenIDs: [11],
            tokenizerEOSTokenID: 22,
            extraEOSTokens: ["<extra-eos>"],
            convertTokenToID: { $0 == "<extra-eos>" ? 33 : nil })
        #expect(policy == [11, 22, 33])

        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: ConfiguredStopEngine(stopToken: 33)) { .inactive }
        }
        let report = try await MTPBenchmarkRunner.run(
            target: artifact,
            assistant: artifact,
            hardware: testHardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: [.init(name: "extra-stop", tokenIDs: [1])],
                batchSizes: [1],
                modes: [.targetOnly],
                maxTokensPerRow: 2,
                purpose: .productionCorrectness,
                stopPolicy: .production(tokenIDs: policy),
                deadline: .seconds(60)),
            sessions: sessions)
        #expect(report.cases.first?.rows.first?.finishReason == "stop")
        #expect(report.stopPolicy.configuredTokenCount == 3)
    }

    @Test("report destination survives visible parent symlink replacement")
    func descriptorRelativeReportWrite() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-report-race-\(UUID().uuidString)")
        let run = base.appendingPathComponent("run")
        let held = base.appendingPathComponent("held")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let destination = try MTPBenchmarkReportDestination.open(
            directoryURL: run,
            fileName: "report.json")
        let outsideFile = outside.appendingPathComponent("victim.json")
        try Data("sentinel".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: run.appendingPathComponent("report.json"),
            withDestinationURL: outsideFile)
        try FileManager.default.moveItem(at: run, to: held)
        try FileManager.default.createSymbolicLink(at: run, withDestinationURL: outside)
        let report = minimalReport(purpose: .rawParityStress)
        try report.write(to: destination)

        #expect(FileManager.default.fileExists(
            atPath: held.appendingPathComponent("report.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("report.json").path))
        #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "sentinel")
    }

    @Test("coverage labels follow inspected target and assistant formats")
    func dynamicCoverageLabels() {
        let target = MTPBenchmarkArtifactFacts(
            modelID: "custom/target",
            resolvedPath: "/tmp/target",
            revision: nil,
            modelType: "gemma4",
            architecture: nil,
            dtype: "bfloat16",
            quantization: .init(
                bits: nil,
                groupSize: 64,
                mode: "affine",
                perLayerOverridesByBits: ["8": 12]),
            weightFiles: [])
        let assistant = MTPBenchmarkArtifactFacts(
            modelID: "custom/assistant",
            resolvedPath: "/tmp/assistant",
            revision: nil,
            modelType: "gemma4_assistant",
            architecture: nil,
            dtype: "bfloat16",
            quantization: nil,
            weightFiles: [])
        let coverage = MTPBenchmarkCoverage.shortContextMatrix(
            target: target, assistant: assistant)
        #expect(coverage.eightBitTargetPairing == .covered)
        #expect(coverage.bf16AssistantPairing == .covered)
        #expect(coverage.qat4BitShortContextSmoke == .notRun)
    }

    @Test("production stop requires the final emitted token to be configured")
    func stopTokenMustBeEmitted() async throws {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: InvalidStopEngine()) { .inactive }
        }
        await #expect(throws: MTPBenchmarkError.self) {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: 1,
                    purpose: .productionCorrectness,
                    stopPolicy: .production(tokenIDs: [9]),
                    deadline: .seconds(60)),
                sessions: sessions)
        }
    }

    @Test("parity requires matching finish reasons, not only tokens")
    func parityComparesFinishReasons() async throws {
        let artifact = testArtifact()
        let fixedMetrics = MTPBenchmarkMetrics(
            active: true,
            verificationMode: "automatic",
            maxAutomaticRectangularTokens: 8,
            selectedDepth: 0,
            decodeRowBucket: 1,
            depthSelections: ["0": 1])
        let sessions = MTPBenchmarkSessionFactory { mode, _ in
            if mode.kind == .targetOnly {
                return MTPBenchmarkSession(
                    engine: ConfiguredStopEngine(stopToken: 9)) { .inactive }
            }
            return MTPBenchmarkSession(
                engine: SameTokenLengthEngine(token: 9)) { fixedMetrics }
        }
        // Both engines emit the identical single token 9 at the budget; only
        // the OpenAI-visible finish reason differs (stop vs length). Token
        // parity alone would certify this divergence.
        do {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1])],
                    batchSizes: [1],
                    modes: [.targetOnly, try .fixed(verificationWidth: 1)],
                    maxTokensPerRow: 1,
                    purpose: .productionCorrectness,
                    stopPolicy: .production(tokenIDs: [9]),
                    deadline: .seconds(60)),
                sessions: sessions)
            Issue.record("identical tokens with divergent finish reasons were certified")
        } catch let error as MTPBenchmarkError {
            #expect(error.description.contains("finish reasons diverge"))
        }
    }

    @Test("production stop terminal must not exceed maxTokens")
    func stopTerminalMustNotOvershoot() async throws {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: OvershootStopEngine(stopToken: 9)) { .inactive }
        }
        // The engine emits two tokens (7, then EOS 9) against a budget of 1:
        // a valid stop membership that still violates the OpenAI-visible
        // max-token limit and must be rejected.
        do {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: 1,
                    purpose: .productionCorrectness,
                    stopPolicy: .production(tokenIDs: [9]),
                    deadline: .seconds(60)),
                sessions: sessions)
            Issue.record("benchmark certified a stop terminal past maxTokens")
        } catch let error as MTPBenchmarkError {
            #expect(error.description.contains("production terminal within maxTokens"))
        }
    }

    @Test("token parity mismatch and missing baseline cannot certify")
    func parityMismatchCannotCertify() async throws {
        let artifact = testArtifact()
        let fixedMetrics = MTPBenchmarkMetrics(
            active: true,
            verificationMode: "automatic",
            maxAutomaticRectangularTokens: 8,
            selectedDepth: 0,
            decodeRowBucket: 1,
            depthSelections: ["0": 1])
        // Target-only emits token 9; the MTP session emits a DIFFERENT valid
        // token 7 — target authority requires this to fail certification.
        let sessions = MTPBenchmarkSessionFactory { mode, _ in
            if mode.kind == .targetOnly {
                return MTPBenchmarkSession(
                    engine: ConfiguredStopEngine(stopToken: 9)) { .inactive }
            }
            return MTPBenchmarkSession(
                engine: SameTokenLengthEngine(token: 7)) { fixedMetrics }
        }
        func configuration(modes: [MTPBenchmarkMode]) -> MTPBenchmarkConfiguration {
            MTPBenchmarkConfiguration(
                prompts: [.init(name: "prompt", tokenIDs: [1])],
                batchSizes: [1],
                modes: modes,
                maxTokensPerRow: 1,
                purpose: .productionCorrectness,
                stopPolicy: .production(tokenIDs: [9, 7]),
                deadline: .seconds(60))
        }
        do {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact, assistant: artifact, hardware: testHardware(),
                configuration: configuration(
                    modes: [.targetOnly, try .fixed(verificationWidth: 1)]),
                sessions: sessions)
            Issue.record("divergent tokens were certified as parity")
        } catch MTPBenchmarkError.tokenParityMismatch(let mode, let batchSize, let rows) {
            #expect(mode == "fixed-L1")
            #expect(batchSize == 1)
            #expect(rows == [0])
        }
        // A configuration without the target-only baseline cannot even start.
        await #expect(throws: MTPBenchmarkError.self) {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact, assistant: artifact, hardware: testHardware(),
                configuration: configuration(
                    modes: [try .fixed(verificationWidth: 1)]),
                sessions: sessions)
        }
    }

    @Test("production length terminal must reach maxTokens")
    func lengthTerminalMustReachMaxTokens() async throws {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: SuccessfulLengthEngine()) { .inactive }
        }
        func run(maxTokensPerRow: Int) async throws -> MTPBenchmarkReport {
            try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: maxTokensPerRow,
                    purpose: .productionCorrectness,
                    stopPolicy: .production(tokenIDs: [9]),
                    deadline: .seconds(60)),
                sessions: sessions)
        }
        // The engine emits exactly one token before its "length" terminal, so a
        // budget of 2 is a premature truncation and must be rejected.
        do {
            _ = try await run(maxTokensPerRow: 2)
            Issue.record("benchmark certified a truncated length terminal")
        } catch let error as MTPBenchmarkError {
            #expect(error.description.contains(
                "production length terminal reached maxTokens"))
        }
        // Reaching the budget exactly is a valid production length terminal.
        let report = try await run(maxTokensPerRow: 1)
        #expect(report.cases.first?.rows.first?.finishReason == "length")
    }

    @Test("deadline includes session construction")
    func deadlineIncludesSessionConstruction() async throws {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            try await Task<Never, Never>.sleep(nanoseconds: 40_000_000)
            return MTPBenchmarkSession(engine: SuccessfulLengthEngine()) { .inactive }
        }
        await expectDeadline(artifact: artifact, deadline: .milliseconds(10), sessions: sessions)
    }

    @Test("deadline includes synchronous submission")
    func deadlineIncludesSubmission() async throws {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: SlowSubmissionEngine()) { .inactive }
        }
        await expectDeadline(artifact: artifact, deadline: .milliseconds(10), sessions: sessions)
    }

    @Test("deadline includes engine shutdown")
    func deadlineIncludesShutdown() async throws {
        let artifact = testArtifact()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: SlowShutdownEngine()) { .inactive }
        }
        await expectDeadline(artifact: artifact, deadline: .milliseconds(10), sessions: sessions)
    }

    @Test("per-case remaining deadline cancels a hanging batch")
    func remainingDeadlineCancelsBatch() async throws {
        let artifact = testArtifact()
        let engine = HangingEngine()
        let sessions = MTPBenchmarkSessionFactory { _, _ in
            MTPBenchmarkSession(engine: engine) { .inactive }
        }
        do {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1, 2])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: 1,
                    purpose: .rawParityStress,
                    stopPolicy: .rawFixedLength,
                    deadline: .milliseconds(20)),
                sessions: sessions)
            Issue.record("benchmark accepted a batch past its remaining deadline")
        } catch let error as MTPBenchmarkError {
            if case .deadlineExceeded = error {
                #expect(engine.cancelled)
            } else {
                Issue.record("unexpected deadline error: \(error)")
            }
        }
    }

    private func testArtifact() -> MTPBenchmarkArtifactFacts {
        MTPBenchmarkArtifactFacts(
            modelID: "test",
            resolvedPath: "/tmp/test",
            revision: nil,
            modelType: "gemma4",
            architecture: nil,
            dtype: "bfloat16",
            quantization: nil,
            weightFiles: [])
    }

    private func testHardware() -> MTPBenchmarkHardware {
        MTPBenchmarkHardware(
            machineModel: "Mac",
            chipName: "Apple",
            chipFamily: "m4",
            chipTier: "max",
            memoryGB: 64,
            gpuCores: 40,
            memoryBandwidthGBps: 500)
    }

    private func minimalReport(purpose: MTPBenchmarkPurpose) -> MTPBenchmarkReport {
        let artifact = testArtifact()
        return MTPBenchmarkReport(
            runFingerprint: "minimal",
            purpose: purpose,
            stopPolicy: purpose == .rawParityStress
                ? .rawFixedLength
                : .production(tokenIDs: [9]),
            startedAt: Date(),
            completedAt: Date(),
            complete: true,
            expectedCaseCount: 0,
            target: artifact,
            assistant: artifact,
            hardware: testHardware(),
            maxTokensPerRow: 1,
            warmupIterations: 0,
            measurementRepetitions: 1,
            modeOrderSeed: 1,
            coverage: .shortContextMatrix(target: artifact, assistant: artifact),
            elapsedMs: 1,
            cases: [])
    }

    private func findKeys(in value: Any, matching wanted: Set<String>) -> [String] {
        if let object = value as? [String: Any] {
            return object.flatMap { key, child in
                (wanted.contains(key) ? [key] : []) + findKeys(in: child, matching: wanted)
            }
        }
        if let values = value as? [Any] {
            return values.flatMap { findKeys(in: $0, matching: wanted) }
        }
        return []
    }

    private func expectDeadline(
        artifact: MTPBenchmarkArtifactFacts,
        deadline: Duration,
        sessions: MTPBenchmarkSessionFactory
    ) async {
        do {
            _ = try await MTPBenchmarkRunner.run(
                target: artifact,
                assistant: artifact,
                hardware: testHardware(),
                configuration: MTPBenchmarkConfiguration(
                    prompts: [.init(name: "prompt", tokenIDs: [1])],
                    batchSizes: [1],
                    modes: [.targetOnly],
                    maxTokensPerRow: 1,
                    purpose: .rawParityStress,
                    stopPolicy: .rawFixedLength,
                    deadline: deadline),
                sessions: sessions)
            Issue.record("benchmark exceeded its case deadline")
        } catch let error as MTPBenchmarkError {
            if case .deadlineExceeded = error {
                return
            }
            Issue.record("unexpected deadline error: \(error)")
        } catch {
            Issue.record("unexpected deadline error: \(error)")
        }
    }
}

private final class TerminalErrorEngine: CBv2Engine, @unchecked Sendable {
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in
            continuation.yield(.delta(text: "x", tokens: [7], logprobs: nil))
            continuation.yield(.finished(
                reason: .error("injected"),
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: 1)))
            continuation.finish()
        }
    }

    func cancel(_: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 0,
            activeTokens: 0)
    }

    func shutdown() async {}
}

private final class SuccessfulLengthEngine: CBv2Engine, @unchecked Sendable {
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        successfulLengthStream(request)
    }

    func cancel(_: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 0,
            activeTokens: 0)
    }

    func shutdown() async {}
}

/// Emits two tokens ending in the configured stop token and finishes with
/// `.stop` — an overshoot fixture for the production budget bound.
private final class OvershootStopEngine: CBv2Engine, @unchecked Sendable {
    private let stopToken: Int

    init(stopToken: Int) {
        self.stopToken = stopToken
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in
            continuation.yield(.delta(text: "x", tokens: [7, stopToken], logprobs: nil))
            continuation.yield(.finished(
                reason: .stop,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: 2)))
            continuation.finish()
        }
    }

    func cancel(_: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot { emptyCapacity() }
    func shutdown() async {}
}

/// Emits exactly one configurable token and finishes with `.length` — the
/// finish-reason twin of `ConfiguredStopEngine` for parity divergence tests.
private final class SameTokenLengthEngine: CBv2Engine, @unchecked Sendable {
    private let token: Int

    init(token: Int) {
        self.token = token
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in
            continuation.yield(.delta(text: "", tokens: [token], logprobs: nil))
            continuation.yield(.finished(
                reason: .length,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: 1)))
            continuation.finish()
        }
    }

    func cancel(_: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot { emptyCapacity() }
    func shutdown() async {}
}

private final class InvalidStopEngine: CBv2Engine, @unchecked Sendable {
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in
            continuation.yield(.delta(text: "x", tokens: [7], logprobs: nil))
            continuation.yield(.finished(
                reason: .stop,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: 1)))
            continuation.finish()
        }
    }

    func cancel(_: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot { emptyCapacity() }
    func shutdown() async {}
}

private final class ConfiguredStopEngine: CBv2Engine, @unchecked Sendable {
    private let stopToken: Int

    init(stopToken: Int) {
        self.stopToken = stopToken
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        guard request.stopTokens.contains(stopToken) else {
            throw MTPBenchmarkError.invalidStopPolicy(
                "fixture request omitted the configured extra EOS")
        }
        return AsyncStream { continuation in
            continuation.yield(.delta(text: "", tokens: [stopToken], logprobs: nil))
            continuation.yield(.finished(
                reason: .stop,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: 1)))
            continuation.finish()
        }
    }

    func cancel(_: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot { emptyCapacity() }
    func shutdown() async {}
}

private final class SlowSubmissionEngine: CBv2Engine, @unchecked Sendable {
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        Thread.sleep(forTimeInterval: 0.04)
        return successfulLengthStream(request)
    }

    func cancel(_: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot { emptyCapacity() }
    func shutdown() async {}
}

private final class SlowShutdownEngine: CBv2Engine, @unchecked Sendable {
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        successfulLengthStream(request)
    }

    func cancel(_: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot { emptyCapacity() }

    func shutdown() async {
        try? await Task<Never, Never>.sleep(nanoseconds: 40_000_000)
    }
}

private final class HangingEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CBv2Event>.Continuation?
    private var didCancel = false

    var cancelled: Bool { lock.withLock { didCancel } }

    func submit(_: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func cancel(_: CBv2RequestID) {
        let stream = lock.withLock { () -> AsyncStream<CBv2Event>.Continuation? in
            didCancel = true
            return continuation
        }
        stream?.yield(.finished(
            reason: .cancelled,
            usage: CBv2Usage(promptTokens: 2, completionTokens: 0)))
        stream?.finish()
    }

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 1,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 0,
            activeTokens: 0)
    }

    func shutdown() async {}
}

private func successfulLengthStream(_ request: CBv2Request) -> AsyncStream<CBv2Event> {
    AsyncStream { continuation in
        continuation.yield(.delta(text: "x", tokens: [7], logprobs: nil))
        continuation.yield(.finished(
            reason: .length,
            usage: CBv2Usage(
                promptTokens: request.promptTokens.count,
                completionTokens: 1)))
        continuation.finish()
    }
}

private func emptyCapacity() -> CBv2CapacitySnapshot {
    CBv2CapacitySnapshot(
        activeRequests: 0,
        waitingRequests: 0,
        kvBytesInUse: 0,
        kvBytesCapacity: 0,
        activeTokens: 0)
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
