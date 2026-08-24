import Foundation
import SandboxCore

public enum SandboxHostMode: String, Codable, CaseIterable, Sendable {
    case inference
    case draining
    case sandboxDedicated = "sandbox_dedicated"
}

public enum SandboxStorageReservation {
    public static let perSandboxOverheadBytes =
        SandboxResourcePolicy.gibibyte

    public static func growthBytes(
        bootDiskBytes: UInt64,
        workspaceBytes: UInt64
    ) throws -> UInt64 {
        let (diskAndWorkspace, firstOverflow) = bootDiskBytes
            .addingReportingOverflow(workspaceBytes)
        let (total, secondOverflow) = diskAndWorkspace
            .addingReportingOverflow(perSandboxOverheadBytes)
        guard !firstOverflow, !secondOverflow else {
            throw SandboxCapacityError.invalidPolicy
        }
        return total
    }
}

public struct SandboxCapacityPolicy: Equatable, Sendable {
    public static let supportedRunningSandboxes = 2
    public static let maximumSupportedLeaseDurationSeconds: TimeInterval = 600

    public let maximumRunningSandboxes: Int
    public let maximumReservedCPUCount: UInt16
    public let maximumReservedMemoryBytes: UInt64
    public let maximumReservedGrowthBytes: UInt64
    public let storageHeadroomBytes: UInt64
    public let maximumLeaseDurationSeconds: TimeInterval

    public init(
        maximumRunningSandboxes: Int = supportedRunningSandboxes,
        maximumReservedCPUCount: UInt16,
        maximumReservedMemoryBytes: UInt64,
        maximumReservedGrowthBytes: UInt64,
        storageHeadroomBytes: UInt64,
        maximumLeaseDurationSeconds: TimeInterval = 300
    ) throws {
        guard maximumRunningSandboxes == Self.supportedRunningSandboxes,
              maximumReservedCPUCount > 0,
              maximumReservedMemoryBytes > 0,
              maximumReservedGrowthBytes > 0,
              storageHeadroomBytes > 0,
              maximumLeaseDurationSeconds.isFinite,
              (30...Self.maximumSupportedLeaseDurationSeconds)
                  .contains(maximumLeaseDurationSeconds)
        else {
            throw SandboxCapacityError.invalidPolicy
        }
        self.maximumRunningSandboxes = maximumRunningSandboxes
        self.maximumReservedCPUCount = maximumReservedCPUCount
        self.maximumReservedMemoryBytes = maximumReservedMemoryBytes
        self.maximumReservedGrowthBytes = maximumReservedGrowthBytes
        self.storageHeadroomBytes = storageHeadroomBytes
        self.maximumLeaseDurationSeconds = maximumLeaseDurationSeconds
    }
}

public struct SandboxCapacityLease: Codable, Equatable, Sendable {
    public let scope: SandboxOperationScope
    public let virtualMachineName: String
    public let cpuCount: UInt16
    public let memoryBytes: UInt64
    public let workspaceBytes: UInt64
    public let bootDiskBytes: UInt64
    public let reservedGrowthBytes: UInt64
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        scope: SandboxOperationScope,
        virtualMachineName: String,
        cpuCount: UInt16,
        memoryBytes: UInt64,
        workspaceBytes: UInt64,
        bootDiskBytes: UInt64,
        reservedGrowthBytes: UInt64,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.scope = scope
        self.virtualMachineName = virtualMachineName
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.workspaceBytes = workspaceBytes
        self.bootDiskBytes = bootDiskBytes
        self.reservedGrowthBytes = reservedGrowthBytes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(
            SandboxOperationScope.self,
            forKey: .scope
        )
        virtualMachineName = try container.decode(
            String.self,
            forKey: .virtualMachineName
        )
        cpuCount = try container.decode(UInt16.self, forKey: .cpuCount)
        memoryBytes = try container.decode(UInt64.self, forKey: .memoryBytes)
        workspaceBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .workspaceBytes
        ) ?? SandboxResourcePolicy.alpha.workspaceBytes.upperBound
        bootDiskBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .bootDiskBytes
        ) ?? SandboxDiskPolicy.alpha.bootDiskBytes.upperBound
        reservedGrowthBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .reservedGrowthBytes
        ) ?? SandboxStorageReservation.growthBytes(
            bootDiskBytes: bootDiskBytes,
            workspaceBytes: workspaceBytes
        )
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(
            virtualMachineName,
            forKey: .virtualMachineName
        )
        try container.encode(cpuCount, forKey: .cpuCount)
        try container.encode(memoryBytes, forKey: .memoryBytes)
        try container.encode(workspaceBytes, forKey: .workspaceBytes)
        try container.encode(bootDiskBytes, forKey: .bootDiskBytes)
        try container.encode(
            reservedGrowthBytes,
            forKey: .reservedGrowthBytes
        )
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case virtualMachineName
        case cpuCount
        case memoryBytes
        case workspaceBytes
        case bootDiskBytes
        case reservedGrowthBytes
        case issuedAt
        case expiresAt
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

public struct SandboxStorageCapacitySnapshot: Equatable, Sendable {
    public let reservedGrowthBytes: UInt64
    public let storageHeadroomBytes: UInt64
    public let availableStorageBytes: UInt64

    public init(
        reservedGrowthBytes: UInt64,
        storageHeadroomBytes: UInt64,
        availableStorageBytes: UInt64
    ) {
        self.reservedGrowthBytes = reservedGrowthBytes
        self.storageHeadroomBytes = storageHeadroomBytes
        self.availableStorageBytes = availableStorageBytes
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
    case invalidBootDiskBytes
    case duplicateVirtualMachineName
    case activeSandboxGeneration(
        existing: SandboxGeneration,
        requested: SandboxGeneration
    )
    case staleSandboxGeneration(
        highest: SandboxGeneration,
        requested: SandboxGeneration
    )
    case generationHistoryExhausted
    case leaseExpired
    case leaseNotExpired
    case leaseOperationInProgress
    case staleFencingToken
    case leaseNotFound
    case leaseVirtualMachineMismatch
    case leaseResourceMismatch
    case insufficientHostStorage(needed: UInt64, available: UInt64)
    case storageInspectionFailed
    case storageIdentityMismatch
    case fencingTokenExhausted
    case unsafeStatePath
    case publicationUncertain(Int32)
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
        case .invalidBootDiskBytes:
            return "sandbox capacity lease has an invalid boot disk size"
        case .duplicateVirtualMachineName:
            return "virtual machine name is already reserved"
        case .activeSandboxGeneration(let existing, let requested):
            return "sandbox generation \(existing.rawValue) is already active; requested \(requested.rawValue)"
        case .staleSandboxGeneration(let highest, let requested):
            return "sandbox generation \(requested.rawValue) is not newer than durable generation \(highest.rawValue)"
        case .generationHistoryExhausted:
            return "sandbox generation history reached its fail-closed capacity"
        case .leaseExpired:
            return "sandbox capacity lease has expired and cannot be renewed"
        case .leaseNotExpired:
            return "sandbox capacity lease has not expired"
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
        case .insufficientHostStorage(let needed, let available):
            return "sandbox host storage requires \(needed) available bytes; found \(available)"
        case .storageInspectionFailed:
            return "sandbox host storage availability could not be inspected"
        case .storageIdentityMismatch:
            return "sandbox runtime storage does not match the bound capacity volume"
        case .fencingTokenExhausted:
            return "sandbox capacity fencing-token space is exhausted"
        case .unsafeStatePath:
            return "sandbox capacity state path failed ownership or mode checks"
        case .publicationUncertain(let code):
            return "sandbox capacity state publication is uncertain after errno \(code)"
        case .io(let code):
            return "sandbox capacity state I/O failed with errno \(code)"
        }
    }
}
