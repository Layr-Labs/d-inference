import CryptoKit
import Foundation
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Real production bridge submissions. Every stream is admitted before this
/// helper begins consuming output; native forward counters prove actual width.
enum GPTOSSMixedPrefixCohort {
    struct Request: Sendable {
        let id: String
        let tokens: [Int]
        let scope: String
        let answer: String
        let shouldHit: Bool
    }

    struct Output: Codable, Sendable {
        let id: String
        let scope: String
        let promptSHA256: String
        let text: String
        let answer: String
        let hitTokens: Int
        let promptTokens: Int
        let completionTokens: Int
        // Streams may buffer while sibling admissions finish. This is an
        // observer upper bound, not benchmark TTFT or native first-token time.
        let firstObservedChunkSeconds: Double
    }

    private struct Pending: Sendable {
        let index: Int
        let request: Request
        let signal: EngineV2RequestUsageSignal
        let stream: AsyncStream<GenerationEvent>
        let started: ContinuousClock.Instant
    }

    private struct IndexedOutput: Sendable {
        let index: Int
        let value: Output
    }

    static func run(
        bridge: EngineV2Bridge, requests: [Request], label: String,
        requiredDecodeWidth: Int, cacheOn: Bool
    ) async throws -> [Output] {
        try await requireIdle(bridge)
        let rawEngine = await bridge.engine
        let engine = try #require(rawEngine as? EngineV2)
        let before = try engine.beginForwardShapeObservation()

        // Concurrently cross the actual bridge's async staging/admission seam.
        // No sequential awaiting of one entire generation before the next.
        let pending = await withTaskGroup(of: Pending.self) { group in
            for (index, value) in requests.enumerated() {
                group.addTask {
                    let signal = EngineV2RequestUsageSignal()
                    let request = ChatCompletionRequest(model: GPTOSSCheckpointRestartFixture.modelID,
                        messages: [ChatMessage(role: "user", content: "pre-tokenized mixed fixture")],
                        temperature: 0, max_tokens: 256)
                    let started = ContinuousClock.now
                    let stream = await bridge.submitTokenized(promptTokens: value.tokens,
                        request: request, requestId: label + "-" + value.id,
                        cacheScope: value.scope, usageSignal: signal)
                    return Pending(index: index, request: value, signal: signal, stream: stream, started: started)
                }
            }
            var result: [Pending] = []
            for await value in group { result.append(value) }
            return result.sorted { $0.index < $1.index }
        }
        let outputs = try await withThrowingTaskGroup(of: IndexedOutput.self) { group in
            for value in pending {
                group.addTask { IndexedOutput(index: value.index, value: try await collect(value)) }
            }
            var result: [IndexedOutput] = []
            for try await value in group { result.append(value) }
            return result.sorted { $0.index < $1.index }.map(\.value)
        }
        try await requireIdle(bridge)
        let delta = engine.forwardShapeSnapshot().delta(since: before)
        // Retain the observation before asserting, including a failing run.
        let encodedDelta = try JSONEncoder().encode(delta)
        print("[gptoss-mixed-shapes] label=\(label) admitted=\(requests.count) "
            + "requiredDecodeWidth=\(requiredDecodeWidth) delta=\(String(decoding: encodedDelta, as: UTF8.self))")
        #expect(delta.complete && delta.reasons.isEmpty)
        #expect(delta.entries.contains {
            $0.axes.kind == .target && $0.axes.phase == .decode
                && $0.axes.liveBatchRows >= requiredDecodeWidth && $0.completedCalls > 0
        }, "\(label) must exercise real concurrent target decoding, not merely concurrent submission")
        #expect(outputs.count == requests.count)
        for (output, request) in zip(outputs, requests) {
            #expect(output.id == request.id)
            if cacheOn && request.shouldHit {
                // Admission/allocation policy may safely decline an eligible
                // stage. Positive hits must still prove substantial reuse.
                #expect(output.hitTokens == 0 || output.hitTokens >= 4_096,
                        "\(label)/\(request.id) reported an unexpectedly short historical hit")
            } else {
                #expect(output.hitTokens == 0, "\(label)/\(request.id) must take its own cold path")
            }
        }
        if cacheOn {
            let eligibleAnswers = Set(requests.filter(\.shouldHit).map(\.answer))
            let restoredAnswers = Set(zip(outputs, requests).compactMap { output, request in
                request.shouldHit && output.hitTokens >= 4_096 ? request.answer : nil
            })
            #expect(eligibleAnswers.count >= 2 && restoredAnswers == eligibleAnswers,
                    "\(label): both restored suffixes were not exercised; safe misses are not corruption, but missing restored-branch coverage cannot qualify")
        }
        return outputs
    }

    private static func collect(_ pending: Pending) async throws -> Output {
        var text = ""
        var first: ContinuousClock.Instant?
        var failure: String?
        var finish: String?
        var promptTokens: Int?
        var completionTokens: Int?
        for await event in pending.stream {
            switch event {
            case .chunk(let chunk):
                if first == nil && !chunk.isEmpty { first = .now }
                text += chunk
            case .info(let prompt, let completion, _, let reason):
                promptTokens = prompt; completionTokens = completion; finish = reason
            case .error(let message): failure = message
            case .terminal(_, let message, _, _): failure = message
            }
        }
        let answer = stripHarmonyChannelFraming(fromAssistantContent: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = pending.started.duration(to: first ?? .now).components
        let output = Output(id: pending.request.id, scope: pending.request.scope,
            promptSHA256: SHA256.hash(data: try JSONEncoder().encode(pending.request.tokens))
                .map { String(format: "%02x", $0) }.joined(),
            text: text, answer: answer, hitTokens: pending.signal.prefixCacheHitTokens ?? 0,
            promptTokens: promptTokens ?? -1, completionTokens: completionTokens ?? -1,
            firstObservedChunkSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        print("[gptoss-mixed-request] " + String(decoding: try JSONEncoder().encode(output), as: UTF8.self))
        try #require(failure == nil, "\(pending.request.id): \(failure ?? "")")
        try #require(finish == "stop", "\(pending.request.id) must finish naturally, not truncate reasoning")
        #expect(promptTokens == pending.request.tokens.count)
        #expect((completionTokens ?? 0) > 0 && (completionTokens ?? 257) <= 256)
        #expect(first != nil && !answer.isEmpty)
        let normalized = answer.uppercased().trimmingCharacters(in:
            CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'.*")))
        #expect(normalized == pending.request.answer,
                "\(pending.request.id) must answer its own suffix: \(answer)")
        for other in ["ALDER-427", "BRONZE-913", "CEDAR-682"] where other != pending.request.answer {
            #expect(!answer.uppercased().contains(other), "\(pending.request.id) leaked another request's fact: \(answer)")
        }
        return output
    }

    static func requireIdle(_ bridge: EngineV2Bridge) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let capacity = await bridge.capacitySnapshot()
            let idle = capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0
            if idle { return }
            if ContinuousClock.now >= deadline {
                try #require(idle, "mixed cohort admission/KV accounting did not drain")
                return
            }
            try await taskSleep(.milliseconds(10))
        }
    }
}
