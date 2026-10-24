import Foundation
import Testing

@testable import ProviderCore

@Suite("Model prefix benchmark quiescence timing")
struct ModelPrefixBenchmarkQuiescenceTimingTests {
    @Test("the serialized-request rate includes a later idle/write tail without moving the receipt boundary")
    func separateCompletionBoundaries() {
        let started = ContinuousClock.now
        let receipt = started.advanced(by: .seconds(2))
        let result = ModelPrefixBenchmarkQuiescenceTiming(started: started,
            receiptCompleted: receipt, quiescenceCompleted: started.advanced(by: .seconds(5)),
            outputTokens: 100)
        #expect(result.quiescenceCompletionSeconds == 5)
        #expect(result.receiptToQuiescenceMilliseconds == 3_000)
        #expect(result.quiescenceCompletionTPS == 20)
        #expect(result.checkpointWritesDrained)
        #expect(result.quiescenceCompletionTPS != 50,
            "the earlier receipt rate must not stand in for completed serialized work")
    }

    @Test("quiescence waits for a real pending pipeline consumer after observing idle")
    func actualPipelineDrainOrdersQuiescence() async throws {
        let entered = Gate(), release = Gate(), draining = Gate()
        let probe = Probe()
        let pipeline = BoundedSingleConsumerPipeline<Int>(capacity: 1) { _ in
            await entered.open()
            await release.wait()
        }
        #expect(pipeline.submit(1))
        await entered.wait()
        let started = ContinuousClock.now
        let measurement = Task {
            let result = try await ModelPrefixBenchmarkQuiescenceTiming.measure(
                started: started, receiptCompleted: started, outputTokens: 128,
                requireIdle: { await probe.observedIdle() },
                drainCheckpointWrites: {
                    #expect(await probe.idle)
                    await draining.open()
                    await pipeline.waitUntilDrained()
                })
            await probe.completed()
            return result
        }
        await draining.wait()
        #expect(await probe.finished == false,
            "pending writer work cannot become a successful quiescence receipt")
        await release.open()
        let result = try await measurement.value
        #expect(await probe.finished)
        #expect(result.checkpointWritesDrained && result.receiptToQuiescenceMilliseconds >= 0)
        pipeline.shutdown()
        await pipeline.waitUntilDrained()
    }

    @Test("a refused quiescence barrier cannot produce drained status")
    func failedBarrierDoesNotComplete() async {
        let probe = Probe()
        await #expect(throws: BarrierFailure.refused) {
            _ = try await ModelPrefixBenchmarkQuiescenceTiming.measure(
                started: .now, receiptCompleted: .now, outputTokens: 128,
                requireIdle: { throw BarrierFailure.refused },
                drainCheckpointWrites: { await probe.completed() })
        }
        #expect(await probe.finished == false)
    }

    private enum BarrierFailure: Error, Equatable { case refused }

    private actor Probe {
        private(set) var idle = false
        private(set) var finished = false
        func observedIdle() { idle = true }
        func completed() { finished = true }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
}
