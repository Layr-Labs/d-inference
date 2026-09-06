import Foundation
import ProviderCoreFoundation

enum ModelDownloadAdmissionError: Error, Equatable, LocalizedError, Sendable {
    case missingPlan(modelID: String)
    case malformedPlan(modelID: String, reason: String)
    case unknownCapacity(modelID: String)
    case insufficientCapacity(requiredBytes: Int64, availableBytes: Int64)
    case activeDownloadsReserved(
        requiredBytes: Int64,
        availableBytes: Int64,
        reservedBytes: Int64
    )

    var errorDescription: String? {
        switch self {
        case .missingPlan:
            return "Darkbloom could not obtain a fresh storage plan. No download was started."
        case .malformedPlan(_, let reason):
            return "Darkbloom received an invalid storage plan (\(reason)). No download was started."
        case .unknownCapacity:
            return "This Mac did not report usable free-space capacity. No download was started."
        case .insufficientCapacity(let required, let available):
            return Self.capacityMessage(required: required, available: available)
        case .activeDownloadsReserved(let required, let available, let reserved):
            return Self.capacityMessage(required: required, available: available)
                + " Active model downloads already reserve \(Self.bytes(reserved)) of that capacity."
        }
    }

    private static func capacityMessage(required: Int64, available: Int64) -> String {
        "Not enough disk space to download this model while preserving Darkbloom's safety reserve "
            + "(requires \(bytes(required)), \(bytes(available)) available)."
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct ValidatedModelDownloadStoragePlan: Equatable, Sendable {
    let remainingBytes: Int64
    let reserveBytes: Int64
    let requiredAvailableBytes: Int64
    let availableBytes: Int64

    static func validate(
        _ plan: CLIModelDownloadStoragePlan?,
        modelID: String,
        minimumReserveBytes: Int64 = ModelDownloadStorageContract.appReserveBytes
    ) throws -> Self {
        guard let plan else {
            throw ModelDownloadAdmissionError.missingPlan(modelID: modelID)
        }
        guard plan.remainingBytes >= 0 else {
            throw malformed(modelID, "remaining bytes are negative")
        }
        guard plan.reserveBytes >= minimumReserveBytes else {
            throw malformed(modelID, "the safety reserve is below the app minimum")
        }
        let (required, overflow) = plan.remainingBytes.addingReportingOverflow(
            plan.reserveBytes
        )
        guard !overflow else {
            throw malformed(modelID, "required-byte arithmetic overflowed")
        }
        guard plan.requiredAvailableBytes == required else {
            throw malformed(modelID, "required bytes do not equal remaining bytes plus reserve")
        }
        guard let available = plan.availableBytes else {
            throw ModelDownloadAdmissionError.unknownCapacity(modelID: modelID)
        }
        guard available >= 0 else {
            throw malformed(modelID, "available bytes are negative")
        }

        let computedSufficient = available >= required
        guard plan.hasSufficientCapacity == computedSufficient else {
            throw malformed(modelID, "the capacity verdict conflicts with the byte fields")
        }
        guard computedSufficient else {
            throw ModelDownloadAdmissionError.insufficientCapacity(
                requiredBytes: required,
                availableBytes: available
            )
        }
        return Self(
            remainingBytes: plan.remainingBytes,
            reserveBytes: plan.reserveBytes,
            requiredAvailableBytes: required,
            availableBytes: available
        )
    }

    private static func malformed(
        _ modelID: String,
        _ reason: String
    ) -> ModelDownloadAdmissionError {
        .malformedPlan(modelID: modelID, reason: reason)
    }
}

/// One-shot bridge between asynchronous preflight and synchronous process
/// creation. Dropping an unstarted preparation releases its reservation; a
/// started preparation transfers release ownership to the event stream.
final class PreparedModelDownload: @unchecked Sendable {
    private enum State: Equatable {
        case ready
        case started
        case cancelled
    }

    let modelID: String
    let plan: ValidatedModelDownloadStoragePlan

    private let lock = NSLock()
    private var state = State.ready
    private let startBody:
        @Sendable () -> AsyncThrowingStream<ModelDownloadStreamEvent, Error>
    private let cancelBody: @Sendable () -> Void

    init(
        modelID: String,
        plan: ValidatedModelDownloadStoragePlan,
        start: @escaping @Sendable ()
            -> AsyncThrowingStream<ModelDownloadStreamEvent, Error>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.modelID = modelID
        self.plan = plan
        startBody = start
        cancelBody = cancel
    }

    deinit {
        cancel()
    }

    func start() throws -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        try Task.checkCancellation()
        let mayStart = lock.withLock {
            guard state == .ready else { return false }
            state = .started
            return true
        }
        guard mayStart else { throw CancellationError() }
        return startBody()
    }

    func cancel() {
        let shouldCancel = lock.withLock {
            guard state == .ready else { return false }
            state = .cancelled
            return true
        }
        if shouldCancel {
            cancelBody()
        }
    }
}

/// Serializes app admissions and conservatively accounts for every active
/// download's full admitted remainder until its stream terminates.
actor AppModelDownloadAdmissionController {
    static let shared = AppModelDownloadAdmissionController()

    struct Admission: Sendable {
        let id: UUID
        let modelID: String
        let plan: ValidatedModelDownloadStoragePlan
    }

    private var reservations: [UUID: Int64] = [:]
    private var reservedRemainingBytes: Int64 = 0

    func admit(
        modelID: String,
        plan: CLIModelDownloadStoragePlan?
    ) throws -> Admission {
        let validated = try ValidatedModelDownloadStoragePlan.validate(
            plan,
            modelID: modelID
        )
        let (requiredWithReservations, overflow) =
            validated.requiredAvailableBytes.addingReportingOverflow(
                reservedRemainingBytes
            )
        guard !overflow else {
            throw ModelDownloadAdmissionError.malformedPlan(
                modelID: modelID,
                reason: "active reservation arithmetic overflowed"
            )
        }
        guard validated.availableBytes >= requiredWithReservations else {
            throw ModelDownloadAdmissionError.activeDownloadsReserved(
                requiredBytes: requiredWithReservations,
                availableBytes: validated.availableBytes,
                reservedBytes: reservedRemainingBytes
            )
        }

        let (nextReserved, reservationOverflow) =
            reservedRemainingBytes.addingReportingOverflow(
                validated.remainingBytes
            )
        guard !reservationOverflow else {
            throw ModelDownloadAdmissionError.malformedPlan(
                modelID: modelID,
                reason: "reservation accounting overflowed"
            )
        }

        let admission = Admission(id: UUID(), modelID: modelID, plan: validated)
        reservations[admission.id] = validated.remainingBytes
        reservedRemainingBytes = nextReserved
        return admission
    }

    func release(_ admission: Admission) {
        guard let bytes = reservations.removeValue(forKey: admission.id) else {
            return
        }
        reservedRemainingBytes = max(0, reservedRemainingBytes - bytes)
    }

    func reservationSnapshot() -> (count: Int, bytes: Int64) {
        (reservations.count, reservedRemainingBytes)
    }
}
