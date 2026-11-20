import Foundation

// Host-only injection seam for model-free HTTP/lifecycle tests. The public
// initializer accepts the installed session; it has the sole device ownership.
protocol DistributedLocalServerSession: DistributedDeadlineExecutionOwner {
    var httpDiagnosticObservation: ClusterSessionObservation? { get }
    var httpInstalledBinding: ClusterStatusBinding? { get }
    var model: DistributedInstalledModel { get }
    var expectedIdentity: DistributedResidentIdentity { get }
    var profile: DistributedResidentExecutionProfile { get }
    var status: DistributedInstalledSessionStatus { get }
    var httpAdmissionAvailable: Bool { get }
    var httpSessionInvalid: Bool { get }
    var httpSessionExhausted: Bool { get }
    var httpCanRotate: Bool { get }
    var httpDrainOnExhaustion: Bool { get }
    var lifetimeDeadlineUptimeNanoseconds: UInt64? { get }
    func httpStopTokenIDs(tokenizerEOS: Int?) throws -> Set<Int>
    func validateModelInputs() throws
    func start() async throws
    func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus
    func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus
}

extension DistributedLocalServerSession {
    var httpDiagnosticObservation: ClusterSessionObservation? { nil }
    var httpInstalledBinding: ClusterStatusBinding? { httpDiagnosticObservation?.binding }
    var httpCanRotate: Bool { status == .released }
    var httpDrainOnExhaustion: Bool { false }
    func httpStopTokenIDs(tokenizerEOS: Int?) throws -> Set<Int> { try model.stopTokenIDs(tokenizerEOS: tokenizerEOS) }
}

extension DistributedInstalledSession: DistributedLocalServerSession {
    var httpDiagnosticObservation: ClusterSessionObservation? { diagnosticObservation }
    var httpCanRotate: Bool { canRotate }
    var httpAdmissionAvailable: Bool { status == .ready && admissionState?.canAdmit() == true }
    var httpSessionInvalid: Bool { admissionState?.isValid == false }
    var httpSessionExhausted: Bool {
        guard let state = admissionState else { return false }
        return state.isValid && state.admissionsRemaining == 0 && !state.hasActiveRequest
    }
}

public enum DistributedLocalServerPhase: String, Sendable {
    case prepared, starting, serving, rotating, draining, stopping, quarantined, stopped
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
    case alreadyStarted, startupInterrupted, bindFailed, bindTimedOut, lifetimeExpired
    case replacementIdentityChanged, replacementNotPrepared, replacementNotReleased
}
