import CryptoKit
import Foundation
import MLXLMServer

@testable import ProviderCore

extension ServingQualificationFixture {
    func collect(request: OpenAIChatCompletionRequest, tokens: [Int], id: String,
                 progress: QualificationStreamProgress? = nil) async -> ServingQualificationRow {
        let profile = RequestProfileBuilder()
        let usage = EngineV2RequestUsageSignal()
        let start = ContinuousClock.now
        var arrivals: [Double] = []
        var output = SHA256()
        var completion = 0
        var failure: String?
        let promptWork = job.firstContentBudgetMilliseconds.map { _ in
            PromptWork(source: "exact_contract", promptTokens: tokens.count, upperBoundTokens: tokens.count,
                promptContractID: promptContractID, modelArtifactHash: job.artifactSHA256)
        }
        do {
            let frames = try await service(profile: profile, usage: usage, promptWork: promptWork)
                .streamChatCompletionFrames(request: request)
            for try await frame in frames {
                try Task.checkCancellation()
                guard frame.hasPrefix("data: "), frame != ServerSentEventEncoder.done else { continue }
                let json = String(frame.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                let chunk = try JSONDecoder().decode(OpenAIChatCompletionChunk.self, from: Data(json.utf8))
                if let count = chunk.usage?.completionTokens { completion = count }
                let delta = chunk.choices.first?.delta
                if let delta {
                    // Match actual nonempty content/tool/reasoning output,
                    // excluding the initial assistant-role envelope.
                    let content = delta.content ?? ""
                    let reasoning = delta.reasoningContent ?? ""
                    let hasTools = delta.toolCalls?.isEmpty == false
                    if !content.isEmpty || !reasoning.isEmpty || hasTools {
                        progress?.observeContent()
                        arrivals.append(Self.milliseconds(start.duration(to: .now)))
                        output.update(data: Data((content + reasoning).utf8))
                        if let tools = delta.toolCalls {
                            output.update(data: try JSONEncoder().encode(tools))
                        }
                    }
                }
            }
        } catch {
            // Retain every unsuccessful observation with a closed class;
            // raw errors may contain request content and are never receipts.
            failure = error is CancellationError ? "cancelled" : "request_failed"
        }
        if arrivals.isEmpty, failure == nil { failure = "no_first_content" }
        let elapsed = Self.milliseconds(start.duration(to: .now))
        await usage.waitForTerminalObservation()
        progress?.finish()
        let wireProfile = profile.wireObject()
        let evidence = job.firstContentBudgetMilliseconds.map { budget in
            ServingQualificationDeadlineEvidence.capture(profile: wireProfile,
                reviewedProfileID: bundle.bridge.deadlineProfile?.id, promptWork: promptWork,
                budgetMilliseconds: budget, firstContentMilliseconds: arrivals.first)
        }
        let tokenData = (try? JSONEncoder().encode(tokens)) ?? Data()
        return ServingQualificationRow(requestID: id,
            workloadSHA256: SHA256.hash(data: tokenData).map { String(format: "%02x", $0) }.joined(),
            promptTokens: tokens.count, requestedOutputTokens: request.maxTokens ?? job.outputTokens,
            completionTokens: completion, firstContentMs: arrivals.first, contentArrivalMs: arrivals,
            elapsedMs: elapsed, outputSHA256: output.finalize().map { String(format: "%02x", $0) }.joined(),
            cachedTokens: usage.prefixCachePrefillTokensSaved ?? 0, profile: wireProfile, failure: failure,
            deadlineEvidence: evidence)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
