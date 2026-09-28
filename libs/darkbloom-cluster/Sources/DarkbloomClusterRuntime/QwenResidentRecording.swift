import Foundation

/// Benchmark-only CPU result. Encoding completes before the resident owner
/// restores request capacity. The caller still owns durable publication and
/// independent numerical comparison; these diagnostic timings are not TTFT.
@_spi(Benchmark) public struct QwenResidentRecordingCompletion: Sendable {
    public let completion: QwenResidentGenerationCompletion
    public let encodedEvidence: Data
}

enum QwenResidentRequestMode: Equatable {
    case serving, recording

    func require(_ expected: Self) throws {
        guard self == expected else { throw ProbeError("Resident start mode differs from its reservation") }
    }
}

/// Additional named capture storage, charged before a recording request starts.
/// The original allowance remains separate for the driver's source/request
/// rederivation. Encoding/metadata overhead is not a whole-process peak bound.
struct QwenResidentRecordingCharge {
    let base: QwenResidentRequestAllowance
    let capture: QwenGenerationDiagnosticBudget
    let reservedBytes: Int

    static func derive(base: QwenResidentRequestAllowance, rank: Int, vocabularySize: Int,
                       activationDType: String, bound: (Int) throws -> Int) throws -> Self {
        guard base.stateBytes > 0, base.fusionBytes >= 0,
              base.reservedBytes == (try QwenLongPrefillCheckedBytes.sum([base.stateBytes, base.fusionBytes])) else {
            throw ProbeError("Recording charge requires a consistent original request allowance")
        }
        let capture = try QwenGenerationDiagnosticBudget.derive(rank: rank, vocabularySize: vocabularySize,
            activationDType: activationDType, requestReservedBytes: base.reservedBytes, bound: bound)
        return .init(base: base, capture: capture, reservedBytes: try QwenLongPrefillCheckedBytes.sum([
            base.reservedBytes, capture.extraHostBytes, capture.extraNativeBytes,
        ]))
    }

    func requireCapacity(ownerLimit: Int, readinessLimit: Int) throws {
        guard ownerLimit > 0, readinessLimit > 0,
              reservedBytes <= ownerLimit, reservedBytes <= readinessLimit else {
            throw ProbeError("Recording reservation exceeds its combined capture capacity ceiling")
        }
    }

    func requireCapture(_ actual: QwenGenerationDiagnosticBudget) throws {
        guard actual.rank == capture.rank, actual.vocabularySize == capture.vocabularySize,
              actual.activationDType == capture.activationDType,
              actual.logicalRowBytes == capture.logicalRowBytes, actual.float32RowBytes == capture.float32RowBytes,
              actual.extraHostBytes == capture.extraHostBytes, actual.extraNativeBytes == capture.extraNativeBytes,
              actual.originalRequestReservedBytes == base.reservedBytes else {
            throw ProbeError("Diagnostic capture budget differs from the charged reservation")
        }
    }
}

/// Shared serving/recording completion order. The private native body returns
/// only CPU values after retirement; the lifecycle itself cannot prove that.
/// A preparation/encoding failure withdraws capacity even after local scope
/// retirement, and preserves the original error for the outer owner's fence.
enum QwenResidentRequestPublication {
    static func run<NativeValue, Output>(control: QwenResidentControl,
        lifecycle: QwenLayerStageResidentLifecycle,
        identity: QwenLayerStageResidentRequestIdentity, deadline: UInt64,
        body: () throws -> NativeValue, prepare: (NativeValue) throws -> Output
    ) throws -> Output {
        try control.start(identity.requestID)
        do {
            try control.check(deadline: deadline)
            let value = try lifecycle.withRequest(identity: identity, body)
            try control.check(deadline: deadline)
            let output = try prepare(value)
            try control.check(deadline: deadline)
            try control.completed(identity.requestID)
            return output
        } catch {
            control.fail()
            throw error
        }
    }
}
