import Foundation
import SandboxCore

public enum SandboxHostMode: String, Codable, CaseIterable, Sendable {
    case inference
    case draining
    case sandboxDedicated = "sandbox_dedicated"
}

public struct SandboxCapacityPolicy: Equatable, Sendable {
    public static let supportedRunningSandboxes = 2
    public static let maximumSupportedLeaseDurationSeconds: TimeInterval = 600

    public let maximumRunningSandboxes: Int
    public let maximumReservedCPUCount: UInt16
    public let maximumReservedMemoryBytes: UInt64
    public let maximumLeaseDurationSeconds: TimeInterval

    public init(
        maximumRunningSandboxes: Int = supportedRunningSandboxes,
        maximumReservedCPUCount: UInt16,
        maximumReservedMemoryBytes: UInt64,
        maximumLeaseDurationSeconds: TimeInterval = 300
    ) throws {
        guard maximumRunningSandboxes == Self.supportedRunningSandboxes,
              maximumReservedCPUCount > 0,
              maximumReservedMemoryBytes > 0,
              maximumLeaseDurationSeconds.isFinite,
              (30...Self.maximumSupportedLeaseDurationSeconds)
                  .contains(maximumLeaseDurationSeconds)
        else {
            throw SandboxCapacityError.invalidPolicy
        }
        self.maximumRunningSandboxes = maximumRunningSandboxes
        self.maximumReservedCPUCount = maximumReservedCPUCount
        self.maximumReservedMemoryBytes = maximumReservedMemoryBytes
        self.maximumLeaseDurationSeconds = maximumLeaseDurationSeconds
    }
}

public struct SandboxCapacityLease: Codable, Equatable, Sendable {
    public let scope: SandboxOperationScope
    public let virtualMachineName: String
    public let cpuCount: UInt16
    public let memoryBytes: UInt64
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        scope: SandboxOperationScope,
        virtualMachineName: String,
        cpuCount: UInt16,
        memoryBytes: UInt64,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.scope = scope
        self.virtualMachineName = virtualMachineName
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct SandboxCapacitySnapshot: Equatable, Sendable {
    public let mode: SandboxHostMode
    public let leases: [SandboxCapacityLease]

    public init(mode: SandboxHostMode, leases: [SandboxCapacityLease]) {
        self.mode = mode
        self.leases = leases
    }
}

public enum SandboxLeaseOperation: String, Codable, CaseIterable, Sendable {
    case create
    case start
    case execute
    case inspect
    case stop
    case delete

    var requiresActiveLease: Bool {
        switch self {
        case .create, .start, .execute, .inspect:
            true
        case .stop, .delete:
            false
        }
    }
}

package struct SandboxLeaseMutationAuthorization: @unchecked Sendable {
    private let operationLock: SandboxLeaseOperationLock

    init(operationLock: SandboxLeaseOperationLock) {
        self.operationLock = operationLock
    }
}

public enum SandboxCapacityError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPolicy
    case uninitialized
    case corruptState
    case invalidModeTransition(from: SandboxHostMode, to: SandboxHostMode)
    case hostNotAcceptingSandboxes(SandboxHostMode)
    case capacityExhausted
    case invalidLeaseDeadline
    case invalidVirtualMachineName
    case duplicateVirtualMachineName
    case activeSandboxGeneration(
        existing: SandboxGeneration,
        requested: SandboxGeneration
    )
    case leaseExpired
    case leaseOperationInProgress
    case staleFencingToken
    case leaseNotFound
    case leaseVirtualMachineMismatch
    case leaseResourceMismatch
    case fencingTokenExhausted
    case unsafeStatePath
    case io(Int32)

    public var description: String {
        switch self {
        case .invalidPolicy:
            return "sandbox capacity policy is invalid"
        case .uninitialized:
            return "sandbox capacity state is uninitialized"
        case .corruptState:
            return "sandbox capacity state is corrupt"
        case .invalidModeTransition(let from, let to):
            return "invalid host mode transition \(from.rawValue) -> \(to.rawValue)"
        case .hostNotAcceptingSandboxes(let mode):
            return "host mode \(mode.rawValue) is not accepting sandbox reservations"
        case .capacityExhausted:
            return "host sandbox capacity is exhausted"
        case .invalidLeaseDeadline:
            return "sandbox capacity lease deadline is invalid"
        case .invalidVirtualMachineName:
            return "sandbox capacity lease has an invalid virtual machine name"
        case .duplicateVirtualMachineName:
            return "virtual machine name is already reserved"
        case .activeSandboxGeneration(let existing, let requested):
            return "sandbox generation \(existing.rawValue) is already active; requested \(requested.rawValue)"
        case .leaseExpired:
            return "sandbox capacity lease has expired and cannot be renewed"
        case .leaseOperationInProgress:
            return "sandbox capacity lease already has an active mutation"
        case .staleFencingToken:
            return "sandbox capacity command carries a stale fencing token"
        case .leaseNotFound:
            return "sandbox capacity lease was not found"
        case .leaseVirtualMachineMismatch:
            return "sandbox capacity lease does not authorize this virtual machine"
        case .leaseResourceMismatch:
            return "sandbox capacity lease does not authorize these resources"
        case .fencingTokenExhausted:
            return "sandbox capacity fencing-token space is exhausted"
        case .unsafeStatePath:
            return "sandbox capacity state path failed ownership or mode checks"
        case .io(let code):
            return "sandbox capacity state I/O failed with errno \(code)"
        }
    }
}
