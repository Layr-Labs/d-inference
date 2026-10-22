import Foundation
@_spi(GLMCalibration) import MLX

/// Allocation-enforced native backing only. Host/driver budgets and actual
/// process-exit completion remain separate. No soft-limit or sampler fallback.
enum GLM5NextCalibrationNativeCap {
    static func install(bytes: Int) throws {
        guard bytes > 0 else { throw WorkerFailure.invalid("Native cap must be positive") }
        try Memory.installProcessAllocationCap(bytes: bytes)
        try requireInstalled(bytes: bytes)
    }
    static func requireInstalled(bytes: Int) throws {
        guard bytes > 0 else { throw WorkerFailure.invalid("Native cap must be positive") }
        let snapshot = try Memory.processAllocationCapSnapshot()
        let components = [snapshot.heapBytes, snapshot.liveBytes, snapshot.cachedBytes,
            snapshot.pendingBytes, snapshot.unreclaimedBytes]
        var total = 0
        for component in components {
            let sum = total.addingReportingOverflow(component)
            guard component >= 0, !sum.overflow else {
                throw WorkerFailure.invalid("Native allocation-cap accounting is invalid")
            }
            total = sum.partialValue
        }
        guard snapshot.installed, snapshot.limitBytes == bytes,
              snapshot.chargedBytes == total, snapshot.chargedBytes <= bytes,
              snapshot.peakBytes >= snapshot.chargedBytes, snapshot.peakBytes <= bytes else {
            throw WorkerFailure.invalid("Native allocation cap differs from authorization")
        }
    }
}
