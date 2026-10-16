import Foundation

// Host-only injection seam for model-free HTTP/lifecycle tests. The public
// initializer accepts the installed session; it has the sole device ownership.
protocol DistributedLocalServerSession: DistributedDeadlineExecutionOwner {
    var httpDiagnosticObservation: ClusterSessionObservation? { get }
    var model: DistributedInstalledModel { get }
    var expectedIdentity: DistributedResidentIdentity { get }
    var profile: DistributedResidentExecutionProfile { get }
    var status: DistributedInstalledSessionStatus { get }
    var httpAdmissionAvailable: Bool { get }
    var httpSessionInvalid: Bool { get }
    var httpCanRotate: Bool { get }
    /// Identifiers, mode, cut and owner diagnostics for incidents and telemetry (S24).
    var httpObservabilityFacts: DistributedSessionFacts? { get }
    /// Why an unresolved stop is unresolved (S24).
    var httpStopDetail: String? { get }
    func validateModelInputs() throws
    func start() async throws
    func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus
    func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus
}

extension DistributedLocalServerSession {
    var httpDiagnosticObservation: ClusterSessionObservation? { nil }
    var httpCanRotate: Bool { status == .released }
    var httpObservabilityFacts: DistributedSessionFacts? { nil }
    var httpStopDetail: String? { nil }
}

extension DistributedInstalledSession: DistributedLocalServerSession {
    var httpDiagnosticObservation: ClusterSessionObservation? { diagnosticObservation }
    var httpCanRotate: Bool { canRotate }
    var httpAdmissionAvailable: Bool { status == .ready && admissionState?.canAdmit() == true }
    var httpSessionInvalid: Bool { admissionState?.isValid == false }
    var httpObservabilityFacts: DistributedSessionFacts? { observabilityFacts }
    var httpStopDetail: String? { stopDetail }
}

public enum DistributedLocalServerPhase: String, Sendable {
    case prepared, starting, serving, draining, stopping, quarantined, stopped
}

public struct DistributedLocalServerStatus: Sendable {
    public let phase: DistributedLocalServerPhase
    public let publicModelID: String
    public let boundPort: UInt16?
    public let acquisitions: Int
    public let session: DistributedInstalledSessionStatus
    public let failed: Bool
    /// Listener exit alone never sets this flag.
    public var cleanupComplete: Bool { phase == .stopped && session == .released && acquisitions == 0 }
}

public enum DistributedLocalServerError: Error, Sendable {
    case alreadyStarted, startupInterrupted, bindFailed, bindTimedOut
    case replacementIdentityChanged
}
