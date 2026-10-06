import Foundation
import MLX
@_spi(Benchmarking) import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Dedicated serving cancellation and retirement", .serialized)
struct ServingQualificationLifecycleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SERVING_QUALIFICATION_LIFECYCLE"] == "supervised-v1",
                   "requires supervised exclusive hardware qualification"))
    func cancellationRetiresActualWorkAndPreservesGreedyOutput() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_SERVING_QUALIFICATION_JOB"])
        let job = try JSONDecoder().decode(ServingQualificationJob.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let buildIdentity = try ServingQualificationBuildIdentity.capture()
        let fixture = try await ServingQualificationFixture.load(job)
        guard let engine = await fixture.bundle.bridge.ownedEngine as? EngineV2 else {
            await fixture.retire()
            throw QualificationFailure.unsupportedEngine
        }
        let actualKVBackend = await fixture.bundle.bridge.kvBackendKind.rawValue
        var receipts: [LifecycleReceipt] = []
        var cooldowns: [QualificationCooldownReceipt] = []
        var controlPostures: [QualificationTrialPostureReceipt] = []
        func write(passed: Bool) throws {
            let report = LifecycleReport(buildIdentity: buildIdentity, schemaVersion: 1,
                kind: "serving_lifecycle", providerVersion: ProviderCore.version, actualKVBackend: actualKVBackend,
                modelID: job.modelID, artifactSHA256: job.artifactSHA256,
                runtimeRevision: ServingPerformanceProfiles.runtimeRevision, mtp: fixture.mtp,
                runtime: fixture.bundle.bridge.deadlineRuntimeConfiguration, checks: receipts,
                cooldowns: cooldowns, controlPostures: controlPostures, passed: passed)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: job.outputPath), options: .atomic)
        }
        func recover() async throws {
            let cooldown = try await QualificationPostureGate.waitForNominal()
            cooldowns.append(cooldown)
            try write(passed: false)
            guard cooldown.passed else { throw QualificationPostureFailure.recoveryTimedOut }
        }
        do {
            let control = try fixture.request(targetTokens: job.toolHistory ? 2048 : 1024,
                                              nonce: job.runID + "-control")
            try await recover()
            let baselinePosture = QualificationPostureMonitor()
            let baseline = await fixture.collect(request: control.0, tokens: control.1, id: "control-before")
            try #require(baseline.failure == nil && baseline.completionTokens > 0)
            _ = try await fixture.waitForIdle()
            controlPostures.append(await baselinePosture.finish())
            guard controlPostures.last?.isNominal == true else { throw QualificationPostureFailure.nonNominalMeasurement }
            for phase in ["prefill", "after_mtp_content"] {
                let request = try fixture.request(targetTokens: 8192, nonce: job.runID + "-" + phase)
                try await recover()
                let postureMonitor = QualificationPostureMonitor()
                let before = await fixture.bundle.bridge.backendSlotCapacity()
                let beforeSteps = await fixture.bundle.bridge.capacitySnapshot().stepsExecuted
                let beforeRounds = await fixture.bundle.bridge.mtpStatusSnapshot().rounds
                _ = try engine.beginForwardShapeObservation()
                let progress = LifecycleProgress()
                let task = Task { await fixture.consumeForCancellation(request: request.0, progress: progress) }
                var reached = false
                for _ in 0..<3000 {
                    if progress.finished { break }
                    if phase == "prefill" {
                        let capacity = await fixture.bundle.bridge.capacitySnapshot()
                        if capacity.activeRequests > 0 && capacity.stepsExecuted > beforeSteps && !progress.contentSeen {
                            reached = true
                            break
                        }
                        if progress.contentSeen { break }
                    } else if progress.contentSeen,
                        await fixture.bundle.bridge.mtpStatusSnapshot().rounds > beforeRounds {
                        reached = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let fractionBeforeCancel = fixture.budget.serviceBudget.usedFraction
                task.cancel()
                let consumer = await task.value
                let idle = try await fixture.waitForIdle()
                let after = await fixture.bundle.bridge.backendSlotCapacity()
                let posture = await postureMonitor.finish()
                let observation = engine.forwardShapeSnapshot()
                let confirmed = observation.confirmedTokenTimings?.reduce(0) { $0 + $1.tokenCount } ?? 0
                let generated = (after.telemetry?.generatedTokensTotal ?? 0) - (before.telemetry?.generatedTokensTotal ?? 0)
                let generations = (after.telemetry?.generationRequestsTotal ?? 0) - (before.telemetry?.generationRequestsTotal ?? 0)
                let retired = idle.activeRequests == 0 && idle.waitingRequests == 0 && idle.kvBytesReserved == 0
                    && fixture.budget.serviceBudget.count == 0 && fixture.budget.serviceBudget.usedFraction == 0
                #expect(reached && fractionBeforeCancel > 0, "must cancel during the actual requested engine phase")
                #expect(consumer.cancelled, "task cancellation must settle through the real stream")
                #expect(retired, "consumer cancellation cannot leak native KV or whole-machine ownership")
                #expect(observation.droppedTokenTimings == 0)
                #expect(generations == 1, "exactly one generation workload retirement")
                #expect(generated == Int64(confirmed), "all actually committed partial output work remains accounted")
                if phase == "after_mtp_content" { #expect(confirmed > 0) }
                receipts.append(.init(phase: phase, reached: reached, cancelled: consumer.cancelled, engineFinishReason: consumer.engineFinishReason,
                    confirmedTokens: confirmed, generatedTokensAccounted: generated, generationRetirements: generations,
                    serviceFractionAtCancel: fractionBeforeCancel, retired: retired, followupParity: false, posture: posture))
                try write(passed: false)
                guard posture.isNominal else { throw QualificationPostureFailure.nonNominalMeasurement }
                try await recover()
                let followupPosture = QualificationPostureMonitor()
                let followup = await fixture.collect(request: control.0, tokens: control.1, id: "control-after-" + phase)
                _ = try await fixture.waitForIdle()
                controlPostures.append(await followupPosture.finish())
                guard controlPostures.last?.isNominal == true else { throw QualificationPostureFailure.nonNominalMeasurement }
                let parity = followup.failure == nil && followup.outputSHA256 == baseline.outputSHA256
                    && followup.completionTokens == baseline.completionTokens
                #expect(parity, "cancelled work cannot change a subsequent greedy request")
                receipts[receipts.count - 1].followupParity = parity
                try write(passed: false)
            }
            try write(passed: receipts.count == 2 && receipts.allSatisfy { $0.reached && $0.cancelled && $0.retired
                && $0.followupParity && $0.posture.isNominal && $0.generationRetirements == 1
                && $0.generatedTokensAccounted == Int64($0.confirmedTokens) }
                && cooldowns.allSatisfy(\.passed) && controlPostures.allSatisfy(\.isNominal))
            await fixture.retire()
        } catch {
            try? write(passed: false)
            await fixture.retire()
            throw error
        }
    }
}

private final class LifecycleProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var content = false
    private var terminal = false
    var contentSeen: Bool { lock.withLock { content } }
    var finished: Bool { lock.withLock { terminal } }
    func observeContent() { lock.withLock { content = true } }
    func finish() { lock.withLock { terminal = true } }
}

private struct LifecycleReceipt: Codable {
    let phase: String
    let reached: Bool
    let cancelled: Bool
    let engineFinishReason: EngineFinishReason?
    let confirmedTokens: Int
    let generatedTokensAccounted: Int64
    let generationRetirements: Int64
    let serviceFractionAtCancel: Double
    let retired: Bool
    var followupParity: Bool
    let posture: QualificationTrialPostureReceipt
}
private struct LifecycleReport: Encodable {
    let buildIdentity: ServingQualificationBuildIdentity
    let schemaVersion: Int
    let kind: String
    let providerVersion: String
    let actualKVBackend: String
    let modelID: String
    let artifactSHA256: String
    let runtimeRevision: String
    let mtp: ServingMTPConfiguration?
    let runtime: DeadlineRuntimeConfiguration?
    let checks: [LifecycleReceipt]
    let cooldowns: [QualificationCooldownReceipt]
    let controlPostures: [QualificationTrialPostureReceipt]
    let passed: Bool
}

private extension ServingQualificationFixture {
    func consumeForCancellation(request: OpenAIChatCompletionRequest, progress: LifecycleProgress) async -> ServingQualificationLifecycleOutcome {
        let usage = EngineV2RequestUsageSignal()
        let profile = RequestProfileBuilder()
        do {
            let frames = try await service(profile: profile, usage: usage).streamChatCompletionFrames(request: request)
            for try await frame in frames {
                try Task.checkCancellation()
                guard frame.hasPrefix("data: "), frame != ServerSentEventEncoder.done else { continue }
                let body = String(frame.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                let chunk = try JSONDecoder().decode(OpenAIChatCompletionChunk.self, from: Data(body.utf8))
                if let delta = chunk.choices.first?.delta,
                    !(delta.content ?? "").isEmpty || !(delta.reasoningContent ?? "").isEmpty || delta.toolCalls?.isEmpty == false {
                    progress.observeContent()
                }
            }
        } catch {
            // A consumer error or cancelled task is not an engine terminal.
            // The settled profile below owns cancellation classification.
        }
        await usage.waitForTerminalObservation()
        progress.finish()
        return ServingQualificationLifecycleOutcome(engineFinishReason: profile.wireObject().engine?.finishReason)
    }
}
