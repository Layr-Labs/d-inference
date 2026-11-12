import DarkbloomClusterSecurity
import Foundation
import MLX

/// One owner per native group/key pair. Views never make another codec or reset
/// its directional counters. The lock protects flags only, never caller work.
final class CollectiveProtectedSession {
    let binding: ClusterRecordBinding
    let configuration: CollectiveProtectionConfiguration
    private let records: CollectiveAuthenticatedRecords
    private let lock = NSLock()
    private var active = true
    private var inOperation = false

    init(configuration: CollectiveProtectionConfiguration, io: CollectiveRecordByteIO) throws {
        try configuration.resourcePolicy.requireQualified()
        self.configuration = configuration; binding = configuration.binding
        records = try .init(io: io, transport: configuration.makeTransport(io: io))
    }

    deinit { invalidate() }

    var status: ClusterRecordTransportStatus { records.status }

    func invalidate() {
        lock.lock(); active = false; lock.unlock()
        records.invalidate(); configuration.invalidate()
    }

    func send(_ input: MLXArray, scope: CollectiveOperationScope, check: () throws -> Void) throws {
        try operation(scope, shape: input.shape, dtype: input.dtype, sending: true, check: check) {
            try records.sendArray(input, context: scope.context, expectedShape: input.shape,
                expectedDType: input.dtype, check: { try self.checked(check) })
        }
    }

    func receive(shape: [Int], dtype: DType, scope: CollectiveOperationScope,
                 check: () throws -> Void) throws -> MLXArray {
        try operation(scope, shape: shape, dtype: dtype, sending: false, check: check) {
            try records.receiveArray(context: scope.context, expectedShape: shape, expectedDType: dtype,
                check: { try self.checked(check) })
        }
    }

    private func checked(_ check: () throws -> Void) throws {
        try check()
        lock.lock(); let live = active; lock.unlock()
        guard live, records.status.active else { throw ProbeError("Protected native session is inactive") }
    }

    private func operation<T>(_ scope: CollectiveOperationScope, shape: [Int], dtype: DType,
                              sending: Bool, check: () throws -> Void, _ body: () throws -> T) throws -> T {
        lock.lock()
        guard active, !inOperation else {
            active = false; lock.unlock(); records.invalidate(); configuration.invalidate()
            throw ProbeError("Protected native session is inactive or reentered")
        }
        inOperation = true; lock.unlock()
        defer { lock.lock(); inOperation = false; lock.unlock() }
        do {
            try checked(check); try scope.requireBinding(binding)
            // The shared resident owner reserves the session/request charge.
            // Recheck geometry and live resources before host export or crypto.
            let bounds = try CollectiveProtectedOperationBounds(shape: shape, dtype: dtype,
                maximumPlaintextBytes: configuration.limits.maximumPlaintextBytes,
                maximumFrameBytes: configuration.maximumFrameBytes)
            try configuration.resourcePolicy.requireOperation(shape: shape, dtype: dtype)
            try configuration.requireCredit(status: records.status, sending: sending, plaintextBytes: bounds.plaintextBytes)
            let result = try body(); try checked(check); return result
        } catch { invalidate(); throw error }
    }
}
