import Foundation
import MLXLMCommon
@testable import ProviderCore

final class RecoveryStepGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func block() { lock.withLock { didEnter = true }; semaphore.wait() }
    func release() { semaphore.signal() }
}

final class RecoveryReservationDelay: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let seconds: Double
    let gate: RecoveryStepGate?
    init(seconds: Double, gate: RecoveryStepGate?) { self.seconds = seconds; self.gate = gate }
    func observe() {
        let inSubmit = lock.withLock { count += 1; return count == 2 }
        // First quote runs before the bridge's expiry check. Delay the actual
        // engine submit, after that check, to exercise post-commit cleanup.
        if inSubmit {
            gate?.block()
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        }
    }
}

final class RecoverySession: CBv2NativeBlockSession {
    let tokens: Int
    let cancellation: CBv2NativeBlockCancellation
    let gate: RecoveryStepGate?
    let decodeGate: RecoveryStepGate?
    var prefilled = false
    var generatedTokenCount = 0
    var closed = false
    var retainedBytes: Int { closed ? 0 : 64 }
    var activeTokenCount: Int { tokens + generatedTokenCount }
    init(tokens: Int, cancellation: CBv2NativeBlockCancellation, gate: RecoveryStepGate?, decodeGate: RecoveryStepGate?) {
        self.tokens = tokens; self.cancellation = cancellation; self.gate = gate
        self.decodeGate = decodeGate
    }
    func cancel() { closed = true }
    func advanceNative() throws -> CBv2NativeBlockStep {
        if !prefilled {
            gate?.block()
            if cancellation.isCancelled { throw CancellationError() }
            // A real engine phase long enough to pass the unchanged sampling
            // floor/ceiling; this fixture does not claim production throughput.
            Thread.sleep(forTimeInterval: 0.05)
            prefilled = true
            return .prefill(computedTokens: tokens, complete: true)
        }
        decodeGate?.block()
        if cancellation.isCancelled { throw CancellationError() }
        generatedTokenCount += 1
        return .committed(tokens: [65], stopToken: nil, finishReason: .length)
    }
}

final class RecoveryActivityAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var didAttempt = false
    private var didStart = false
    var attempted: Bool { lock.withLock { didAttempt } }
    var started: Bool { lock.withLock { didStart } }
    func markAttempted() { lock.withLock { didAttempt = true } }
    func markStarted() { lock.withLock { didStart = true } }
}

actor RecoveryDeviceActivityOwner {
    private var activity: WholeMacUnboundedActivity?
    func begin(_ budget: WholeMacServiceBudget) { activity = budget.beginUnboundedActivity() }
    func finish() { activity?.finish(); activity = nil }
}
