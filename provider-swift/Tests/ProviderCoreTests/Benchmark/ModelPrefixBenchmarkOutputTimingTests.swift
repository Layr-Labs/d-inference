import Foundation
import Testing

@Suite("Model prefix benchmark observed output timing")
struct ModelPrefixBenchmarkOutputTimingTests {
    @Test("one-token events preserve the ordinary first-to-last interval rate")
    func ordinaryTokenEvents() {
        let first = ContinuousClock.now
        var timing = ModelPrefixBenchmarkOutputTiming()
        timing.record(tokenCount: 0, at: first)
        timing.record(tokenCount: 1, at: first)
        timing.record(tokenCount: 1, at: first.advanced(by: .seconds(1)))
        timing.record(tokenCount: 1, at: first.advanced(by: .seconds(2)))
        #expect(timing.completedOutputTokens == 3 && timing.outputEventCount == 3)
        #expect(timing.firstOutputTokenCount == 1 && timing.generationTPS == 1)
    }

    @Test("a batched first event cannot manufacture individual token timestamps")
    func batchedFirstEvent() {
        let first = ContinuousClock.now
        var timing = ModelPrefixBenchmarkOutputTiming()
        timing.record(tokenCount: 4, at: first)
        timing.record(tokenCount: 3, at: first.advanced(by: .seconds(1)))
        timing.record(tokenCount: 1, at: first.advanced(by: .seconds(2)))
        #expect(timing.completedOutputTokens == 8 && timing.outputEventCount == 3)
        #expect(timing.firstOutputTokenCount == 4 && timing.generationTPS == 2)
        // The old seven-token numerator would incorrectly report3.5TPS.
        #expect(timing.generationTPS != 3.5)
    }

    @Test("one event or a zero observed interval has no generation rate")
    func unobservedInterval() {
        let first = ContinuousClock.now
        var timing = ModelPrefixBenchmarkOutputTiming()
        #expect(timing.generationTPS == nil)
        timing.record(tokenCount: 128, at: first)
        #expect(timing.firstOutputTokenCount == 128 && timing.outputEventCount == 1)
        #expect(timing.generationTPS == nil)
        timing.record(tokenCount: 1, at: first)
        #expect(timing.generationTPS == nil)
    }
}
