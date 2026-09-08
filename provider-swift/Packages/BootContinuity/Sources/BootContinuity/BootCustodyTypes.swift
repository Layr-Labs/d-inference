import Foundation

public enum BootCustodyError: Error, Equatable, Sendable {
    case applicationNotPermitted
    case releaseMismatch
    case recordAlreadyExists
    case noRecoveredSession
    case keychainFailure(Int32)
}

public struct BootContinuityDescriptor: Sendable {
    public let context: BootContinuityContext
    public let publicKey: Data
}

public enum BootContinuityRecovery: Sendable {
    case disabled
    case absent
    /// Possession was checked locally. A coordinator must authorize its use.
    case recovered(BootContinuityDescriptor)
}

protocol BootIdentityStore: Sendable {
    func read(context: BootContinuityContext) throws -> Data?
    /// Insert-only. Existing records are never replaced by this operation.
    func insert(_ data: Data, context: BootContinuityContext) throws
}

protocol BootApplicationScope: Sendable {
    /// Validates the current caller and returns the signed executable CDHash.
    func currentReleaseID() throws -> String
}
