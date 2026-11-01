import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite(.serialized)
struct QwenMediaPreparationTests {
    private actor Gate {
        var didEnter = false
        var entrant: CheckedContinuation<Void, Never>?
        var waiter: CheckedContinuation<Void, Never>?
        func enter() async {
            didEnter = true; entrant?.resume(); entrant = nil
            await withCheckedContinuation { waiter = $0 }
        }
        func waitForEntry() async {
            if didEnter { return }
            await withCheckedContinuation { entrant = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
    }
    private func finished(_ owner: QwenMediaPreparation) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !owner.finished {
            guard ContinuousClock.now < limit else { throw ProbeError("Preparation did not finish") }
            await Task.yield()
        }
    }
    @Test func cancellationDoesNotReleaseAStillRunningDecoder() async throws {
        let owner = QwenMediaPreparation(), gate = Gate()
        try owner.start { await gate.enter(); return [[1, 2, 3]] }
        await gate.waitForEntry()
        owner.cancel()
        #expect(!owner.finished)
        #expect(!owner.releaseIfFinished())
        #expect(throws: (any Error).self) { try owner.take() }
        await gate.release(); try await finished(owner)
        #expect(owner.outcome == .cancelled)
        #expect(throws: (any Error).self) { try owner.take() }
        #expect(owner.releaseIfFinished())
    }
    private final class TeardownGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        let release = DispatchSemaphore(value: 0)
        func enter() { lock.withLock { entered = true }; release.wait() }
        var didEnter: Bool { lock.withLock { entered } }
    }
    private final class DecoderCapture: @unchecked Sendable {
        let gate: TeardownGate
        init(_ gate: TeardownGate) { self.gate = gate }
        deinit { gate.enter() }
    }
    @Test func resultPublicationDoesNotRetireCapturedDecoderTeardown() async throws {
        let owner = QwenMediaPreparation(), gate = TeardownGate()
        defer { gate.release.signal() }
        try owner.start { [capture = DecoderCapture(gate)] in
            withExtendedLifetime(capture) { [[Float(1)]] }
        }
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.didEnter {
            guard ContinuousClock.now < limit else { throw ProbeError("Decoder did not tear down") }
            await Task.yield()
        }
        owner.cancel()
        #expect(!owner.finished)
        #expect(!owner.releaseIfFinished())
        #expect(throws: (any Error).self) { try owner.take() }
        gate.release.signal()
        try await finished(owner)
        #expect(owner.releaseIfFinished())
    }
    @Test func successfulPreparationHasSingleConsumerAndCannotRestart() async throws {
        let owner = QwenMediaPreparation()
        try owner.start { [[1, 2], [3, 4]] }
        try await finished(owner)
        #expect(owner.outcome == .prepared)
        #expect(try owner.take() == [[1, 2], [3, 4]])
        #expect(throws: (any Error).self) { try owner.take() }
        #expect(throws: (any Error).self) { try owner.start { [] } }
        #expect(owner.releaseIfFinished())
        #expect(throws: (any Error).self) { try owner.start { [] } }
    }
    @Test func failureAndUnstartedCancellationRetireWithoutPublishingPixels() async throws {
        let owner = QwenMediaPreparation()
        try owner.start { throw ProbeError("fixture") }
        try await finished(owner)
        #expect(owner.outcome == .failed)
        #expect(throws: (any Error).self) { try owner.take() }
        #expect(owner.releaseIfFinished())
        let unstarted = QwenMediaPreparation()
        unstarted.cancel()
        #expect(unstarted.releaseIfFinished())
        #expect(throws: (any Error).self) { try unstarted.start { [[1]] } }
    }
}
