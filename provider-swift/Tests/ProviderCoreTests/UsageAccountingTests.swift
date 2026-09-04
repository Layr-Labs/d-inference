import Testing
@testable import ProviderCore

@Test("cancel before visible output has no billable usage")
func cancelledUsageWithoutVisibleOutputRefunds() {
    let usage = StreamedGenerationUsage(
        promptTokens: 0,
        completionTokens: 0,
        contentFrameCount: 0,
        hasVisibleOutput: false
    )

    #expect(usage.cancelledUsageInfo(promptTokenFloor: 128) == nil)
    #expect(usage.cancelledTerminal(promptTokenFloor: 128) == .refund)
}

@Test("cancel after visible output settles from conservative floors")
func cancelledUsageAfterVisibleOutputUsesFloors() throws {
    let usage = StreamedGenerationUsage(
        promptTokens: 0,
        completionTokens: 0,
        contentFrameCount: 7,
        hasVisibleOutput: true
    )

    let settled = try #require(usage.cancelledUsageInfo(promptTokenFloor: 321))
    #expect(settled.promptTokens == 321)
    #expect(settled.completionTokens == 7)
    #expect(settled.reasoningTokens == 0)

    #expect(usage.cancelledTerminal(promptTokenFloor: 321) == .complete(settled))
}

@Test("cancel after visible output prefers delivered token floor over frame count")
func cancelledUsageUsesDeliveredTokenFloor() throws {
    let usage = StreamedGenerationUsage(
        promptTokens: 0,
        completionTokens: 0,
        contentFrameCount: 2,
        deliveredCompletionTokenFloor: 19,
        hasVisibleOutput: true
    )

    let settled = try #require(usage.cancelledUsageInfo(promptTokenFloor: 321))
    #expect(settled.promptTokens == 321)
    #expect(settled.completionTokens == 19)
}

@Test("cancel settlement keeps provider-reported usage when present")
func cancelledUsageKeepsReportedCounts() throws {
    let usage = StreamedGenerationUsage(
        promptTokens: 100,
        completionTokens: 50,
        reasoningTokens: 12,
        contentFrameCount: 7,
        hasVisibleOutput: true
    )

    let settled = try #require(usage.cancelledUsageInfo(promptTokenFloor: 321))
    #expect(settled.promptTokens == 100)
    #expect(settled.completionTokens == 50)
    #expect(settled.reasoningTokens == 12)
}

@Test("cancel settlement clamps reasoning tokens to completion tokens")
func cancelledUsageClampsReasoningToCompletion() throws {
    let usage = StreamedGenerationUsage(
        promptTokens: 100,
        completionTokens: 5,
        reasoningTokens: 20,
        contentFrameCount: 7,
        hasVisibleOutput: true
    )

    let settled = try #require(usage.cancelledUsageInfo(promptTokenFloor: 321))
    #expect(settled.promptTokens == 100)
    #expect(settled.completionTokens == 5)
    #expect(settled.reasoningTokens == 5)
}

@Test("an engine-reported prompt count skips the re-template floor entirely")
func enginePromptCountSkipsRetemplateFloor() {
    // Pin (passes before and after the cancel-settlement change): once the
    // handler fills `promptTokens` from the bridge's admission count, the
    // `promptTokenFloor` autoclosure — a full chat-template re-render plus
    // BPE — must never be evaluated. Only a zero prompt count reaches it.
    let usage = StreamedGenerationUsage(
        promptTokens: 17,
        completionTokens: 0,
        contentFrameCount: 3,
        deliveredCompletionTokenFloor: 5,
        hasVisibleOutput: true
    )
    var floorEvaluations = 0
    let terminal = usage.cancelledTerminal(
        promptTokenFloor: { floorEvaluations += 1; return 99 }())
    #expect(terminal == .complete(UsageInfo(promptTokens: 17, completionTokens: 5)))
    #expect(floorEvaluations == 0)

    let zeroPrompt = StreamedGenerationUsage(
        promptTokens: 0,
        completionTokens: 0,
        contentFrameCount: 3,
        deliveredCompletionTokenFloor: 5,
        hasVisibleOutput: true
    )
    let fallback = zeroPrompt.cancelledTerminal(
        promptTokenFloor: { floorEvaluations += 1; return 99 }())
    #expect(fallback == .complete(UsageInfo(promptTokens: 99, completionTokens: 5)))
    #expect(floorEvaluations == 1)
}
