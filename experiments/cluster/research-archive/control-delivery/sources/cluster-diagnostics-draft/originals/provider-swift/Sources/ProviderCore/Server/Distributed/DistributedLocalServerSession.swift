import Foundation

// Host-only injection seam for model-free HTTP/lifecycle tests. The public
// initializer accepts the installed session; it has the sole device ownership.
protocol DistributedLocalServerSession: DistributedDeadlineExecutionOwner {
    var model: DistributedInstalledModel { get }
    var expectedIdentity: DistributedResidentIdentity { get }
    var profile: DistributedResidentExecutionProfile { get }
    var status: DistributedInstalledSessionStatus { get }
    var httpAdmissionAvailable: Bool { get }
    var httpSessionInvalid: Bool { get }
    var httpSessionExhausted: Bool { get }
    var lifetimeDeadlineUptimeNanoseconds: UInt64? { get }
    func validateModelInputs() throws
    func start() async throws
    func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus
    func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus
}

extension DistributedInstalledSession: DistributedLocalServerSession {
    var httpAdmissionAvailable: Bool { status == .ready && admissionState?.canAdmit() == true }
    var httpSessionInvalid: Bool { admissionState?.isValid == false }
    var httpSessionExhausted: Bool {
        guard let state = admissionState else { return false }
        return state.isValid && state.admissionsRemaining == 0 && !state.hasActiveRequest
    }
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
    case alreadyStarted, startupInterrupted, bindFailed, bindTimedOut, lifetimeExpired
}
