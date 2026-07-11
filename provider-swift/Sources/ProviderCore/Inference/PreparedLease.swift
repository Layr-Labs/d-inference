// Copyright © 2026 Eigen Labs.

import Foundation

/// Stable lifecycle states exposed for ProviderLoop integration and tests.
public enum PreparedLeaseState: String, Sendable, Equatable {
    case preparing
    case reserved
    case starting
    case started
    case aborting
    case cancelling
    case aborted
    case cancelled
    case expired
    case completed
    case failed
}

/// Non-emitting reservation returned by a successful prepare operation.
public struct PreparedLease: Sendable, Equatable {
    public let identity: AttemptIdentity
    public var leaseID: LeaseID { identity.leaseID }
    public var requestID: RequestID { identity.requestID }
    public let requestDigest: String
    public let modelID: String
    /// Absolute expiry.  Start authorization at or after this instant loses
    /// to expiry and can never submit work to the engine.
    public let expiresAt: Date
    public let leaseTTLMilliseconds: UInt64
    public let promptTokens: Int
    public let maxOutputTokens: Int
    public let engineQueueDepth: Int
    public let reservedKVBytes: UInt64
    public let reservedMediaBytes: UInt64
    public let prefillCanBegin: Bool
    public let estimatedPrefillMilliseconds: UInt64?

    public func remainingTTLMilliseconds(at now: Date = Date()) -> UInt64 {
        let milliseconds = max(0, expiresAt.timeIntervalSince(now) * 1_000)
        return milliseconds >= Double(UInt64.max)
            ? UInt64.max
            : UInt64(milliseconds.rounded(.down))
    }

    init(
        inference: PreparedInference,
        expiresAt: Date,
        now: Date,
        admission: PreparedInferenceAdmission
    ) {
        self.identity = inference.identity
        self.requestDigest = inference.requestDigest
        self.modelID = inference.modelID
        self.expiresAt = expiresAt
        let milliseconds = max(0, expiresAt.timeIntervalSince(now) * 1_000)
        self.leaseTTLMilliseconds =
            milliseconds >= Double(UInt64.max) ? UInt64.max : UInt64(milliseconds.rounded(.down))
        self.promptTokens = admission.promptTokens
        self.maxOutputTokens = admission.maxOutputTokens
        self.engineQueueDepth = admission.engineQueueDepth
        self.reservedKVBytes = admission.reservedKVBytes
        self.reservedMediaBytes = admission.reservedMediaBytes
        self.prefillCanBegin = admission.prefillCanBegin
        self.estimatedPrefillMilliseconds = admission.estimatedPrefillMilliseconds
    }
}

public enum PreparedLeaseError: Error, Equatable, Sendable {
    case alreadyExpired
    case identityConflict
    case conflictingDuplicate
    case aborted
    case cancelled
    case expired
    case completed
    case failed(String)
    case unknownLease
    case notReady
}

/// Start returns the stream only to the call that won authorization.
/// Duplicate starts are acknowledged without creating a second consumer of
/// the same AsyncStream.
public enum PreparedLeaseStartResult: Sendable {
    case started(PreparedInferenceExecution)
    case alreadyStarted
}

public enum PreparedLeaseControlResult: Sendable, Equatable {
    case aborted
    case alreadyAborted
    /// Abort received after start authorization is cancellation.
    case cancelled
    case alreadyCancelled
    case expired
    case identityConflict
    case failed
}
