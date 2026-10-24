import MLXLMCommon
import Testing

@Suite("Model prefix benchmark terminal cleanup")
struct ModelPrefixBenchmarkTerminalTests {
    @Test("failed, cancelled, missing and short terminals never wait for normal retirement")
    func unsuccessfulTerminalDoesNotWait() async {
        let usage = CBv2Usage(promptTokens: 1_793, completionTokens: 128)
        let cases: [(CBv2FinishReason?, CBv2Usage?, Int, ModelPrefixBenchmarkTerminal.Failure)] = [
            (.error("native evaluation failed"), usage, 128, .incompleteOutput),
            (.cancelled, usage, 128, .incompleteOutput),
            (.stop, usage, 128, .incompleteOutput),
            (nil, usage, 128, .incompleteOutput),
            (.length, nil, 128, .missingUsage),
            (.length, usage, 127, .incompleteOutput),
        ]
        for (finish, finalUsage, count, failure) in cases {
            let retirement = RetirementProbe()
            await #expect(throws: failure) {
                try await ModelPrefixBenchmarkTerminal.completeSuccessfulRequest(
                    finish: finish, usage: finalUsage, outputCount: count,
                    expectedOutputCount: 128) { await retirement.complete() }
            }
            #expect(await retirement.calls == 0,
                "outer fixture shutdown must handle unsuccessful native work")
        }
    }

    @Test("a complete fixed-output terminal waits for real retirement once")
    func successfulTerminalWaits() async throws {
        let retirement = RetirementProbe()
        let usage = try await ModelPrefixBenchmarkTerminal.completeSuccessfulRequest(
            finish: .length,
            usage: .init(promptTokens: 1_793, completionTokens: 128),
            outputCount: 128, expectedOutputCount: 128) { await retirement.complete() }
        #expect(await retirement.calls == 1)
        #expect(usage.promptTokens == 1_793 && usage.completionTokens == 128)
    }

    private actor RetirementProbe {
        private(set) var calls = 0
        func complete() { calls += 1 }
    }
}
