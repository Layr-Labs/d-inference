import Foundation

public let sandboxControlProtocolVersion: UInt16 = 1

public enum SandboxControlMessageType: String, Codable, CaseIterable, Sendable {
    case hostRegister = "sandbox_host_register"
    case hostHeartbeat = "sandbox_host_heartbeat"
    case operationState = "sandbox_operation_state"
    case commandState = "sandbox_command_state"
    case hostFailure = "sandbox_host_failure"
    case prepare = "sandbox_prepare"
    case leaseRenew = "sandbox_lease_renew"
    case command = "sandbox_command"
    case cancelCommand = "sandbox_cancel_command"
    case stop = "sandbox_stop"
    case delete = "sandbox_delete"
    case drain = "sandbox_drain"
}

public enum SandboxWireOperationState: String, Codable, CaseIterable, Sendable {
    case preparing
    case booting
    case ready
    case stopping
    case stopped
    case deleting
    case deleted
    case failed
}

public enum SandboxWireCommandState: String, Codable, CaseIterable, Sendable {
    case accepted
    case running
    case succeeded
    case failed
    case timedOut = "timed_out"
    case cancelled
    case lost
}

public struct SandboxControlEnvelope<Payload>: Codable, Equatable, Sendable
where Payload: Codable & Equatable & Sendable {
    public let type: SandboxControlMessageType
    public let protocolVersion: UInt16
    public let hostID: UUID
    public let connectionEpoch: UUID
    public let sequence: UInt64
    public let payload: Payload

    public init(
        type: SandboxControlMessageType,
        protocolVersion: UInt16 = sandboxControlProtocolVersion,
        hostID: UUID,
        connectionEpoch: UUID,
        sequence: UInt64,
        payload: Payload
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.hostID = hostID
        self.connectionEpoch = connectionEpoch
        self.sequence = sequence
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case hostID = "host_id"
        case connectionEpoch = "connection_epoch"
        case sequence
        case payload
    }
}

public struct SandboxWireHostCapabilities: Codable, Equatable, Sendable {
    public let daemonVersion: String
    public let operatingSystem: String
    public let architecture: String
    public let machineModel: String
    public let chipName: String
    public let cpuCount: UInt16
    public let memoryBytes: UInt64
    public let maximumSandboxes: UInt16
    public let workspaceSizesBytes: [UInt64]
    public let supportsGPU: Bool

    public init(
        daemonVersion: String,
        operatingSystem: String,
        architecture: String,
        machineModel: String,
        chipName: String,
        cpuCount: UInt16,
        memoryBytes: UInt64,
        maximumSandboxes: UInt16,
        workspaceSizesBytes: [UInt64],
        supportsGPU: Bool
    ) {
        self.daemonVersion = daemonVersion
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.machineModel = machineModel
        self.chipName = chipName
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.maximumSandboxes = maximumSandboxes
        self.workspaceSizesBytes = workspaceSizesBytes
        self.supportsGPU = supportsGPU
    }

    private enum CodingKeys: String, CodingKey {
        case daemonVersion = "daemon_version"
        case operatingSystem = "operating_system"
        case architecture
        case machineModel = "machine_model"
        case chipName = "chip_name"
        case cpuCount = "cpu_count"
        case memoryBytes = "memory_bytes"
        case maximumSandboxes = "maximum_sandboxes"
        case workspaceSizesBytes = "workspace_sizes_bytes"
        case supportsGPU = "supports_gpu"
    }
}

public struct SandboxWireHostRegister: Codable, Equatable, Sendable {
    public let capabilities: SandboxWireHostCapabilities

    public init(capabilities: SandboxWireHostCapabilities) {
        self.capabilities = capabilities
    }
}

public struct SandboxWireScope: Codable, Equatable, Sendable {
    public let sandboxID: SandboxID
    public let generation: SandboxGeneration
    public let fencingToken: SandboxFencingToken

    public init(
        sandboxID: SandboxID,
        generation: SandboxGeneration,
        fencingToken: SandboxFencingToken
    ) {
        self.sandboxID = sandboxID
        self.generation = generation
        self.fencingToken = fencingToken
    }

    public init(scope: SandboxOperationScope) {
        self.init(
            sandboxID: scope.sandboxID,
            generation: scope.generation,
            fencingToken: scope.fencingToken
        )
    }

    public var operationScope: SandboxOperationScope {
        SandboxOperationScope(
            sandboxID: sandboxID,
            generation: generation,
            fencingToken: fencingToken
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sandboxID = "sandbox_id"
        case generation
        case fencingToken = "fencing_token"
    }
}

public struct SandboxWireResources: Codable, Equatable, Sendable {
    public let cpuCount: UInt16
    public let memoryBytes: UInt64
    public let workspaceBytes: UInt64
    public let commandTimeoutSeconds: UInt32
    public let gpu: Bool

    public init(
        cpuCount: UInt16,
        memoryBytes: UInt64,
        workspaceBytes: UInt64,
        commandTimeoutSeconds: UInt32,
        gpu: Bool
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.workspaceBytes = workspaceBytes
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.gpu = gpu
    }

    public init(specification: SandboxResourceSpecification, gpu: Bool) {
        self.init(
            cpuCount: specification.cpuCount,
            memoryBytes: specification.memoryBytes,
            workspaceBytes: specification.workspaceBytes,
            commandTimeoutSeconds: specification.commandTimeoutSeconds,
            gpu: gpu
        )
    }

    public var resourceSpecification: SandboxResourceSpecification? {
        try? SandboxResourceSpecification(
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            workspaceBytes: workspaceBytes,
            commandTimeoutSeconds: commandTimeoutSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case cpuCount = "cpu_count"
        case memoryBytes = "memory_bytes"
        case workspaceBytes = "workspace_bytes"
        case commandTimeoutSeconds = "command_timeout_seconds"
        case gpu
    }
}

public struct SandboxWireHostLeaseObservation: Codable, Equatable, Sendable {
    public let scope: SandboxWireScope
    public let state: SandboxWireOperationState
    public let resources: SandboxWireResources
    public let leaseExpiresAt: String

    public init(
        scope: SandboxWireScope,
        state: SandboxWireOperationState,
        resources: SandboxWireResources,
        leaseExpiresAt: String
    ) {
        self.scope = scope
        self.state = state
        self.resources = resources
        self.leaseExpiresAt = leaseExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case state
        case resources
        case leaseExpiresAt = "lease_expires_at"
    }
}

public struct SandboxWireHostHeartbeat: Codable, Equatable, Sendable {
    public let mode: String
    public let availableCPU: UInt16
    public let availableMemoryBytes: UInt64
    public let leases: [SandboxWireHostLeaseObservation]

    public init(
        mode: String,
        availableCPU: UInt16,
        availableMemoryBytes: UInt64,
        leases: [SandboxWireHostLeaseObservation]
    ) {
        self.mode = mode
        self.availableCPU = availableCPU
        self.availableMemoryBytes = availableMemoryBytes
        self.leases = leases
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case availableCPU = "available_cpu"
        case availableMemoryBytes = "available_memory_bytes"
        case leases
    }
}

public struct SandboxWireOperationStatus: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let scope: SandboxWireScope
    public let operation: String
    public let state: SandboxWireOperationState
    public let errorCode: String?

    public init(
        operationID: UUID,
        scope: SandboxWireScope,
        operation: String,
        state: SandboxWireOperationState,
        errorCode: String? = nil
    ) {
        self.operationID = operationID
        self.scope = scope
        self.operation = operation
        self.state = state
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case scope
        case operation
        case state
        case errorCode = "error_code"
    }
}

public struct SandboxWireCommandStatus: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let scope: SandboxWireScope
    public let state: SandboxWireCommandState
    public let exitCode: Int32?
    public let standardOutput: String?
    public let standardError: String?
    public let outputTruncated: Bool
    public let errorCode: String?

    public init(
        commandID: UUID,
        scope: SandboxWireScope,
        state: SandboxWireCommandState,
        exitCode: Int32? = nil,
        standardOutput: String? = nil,
        standardError: String? = nil,
        outputTruncated: Bool = false,
        errorCode: String? = nil
    ) {
        self.commandID = commandID
        self.scope = scope
        self.state = state
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputTruncated = outputTruncated
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case scope
        case state
        case exitCode = "exit_code"
        case standardOutput = "stdout"
        case standardError = "stderr"
        case outputTruncated = "output_truncated"
        case errorCode = "error_code"
    }
}

public struct SandboxWireHostFailure: Codable, Equatable, Sendable {
    public let operationID: UUID?
    public let commandID: UUID?
    public let scope: SandboxWireScope?
    public let errorCode: String

    public init(
        operationID: UUID? = nil,
        commandID: UUID? = nil,
        scope: SandboxWireScope? = nil,
        errorCode: String
    ) {
        self.operationID = operationID
        self.commandID = commandID
        self.scope = scope
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case commandID = "command_id"
        case scope
        case errorCode = "error_code"
    }
}

public struct SandboxWirePrepare: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let scope: SandboxWireScope
    public let resources: SandboxWireResources
    public let baseImageID: String
    public let leaseExpiresAt: String

    public init(
        operationID: UUID,
        scope: SandboxWireScope,
        resources: SandboxWireResources,
        baseImageID: String,
        leaseExpiresAt: String
    ) {
        self.operationID = operationID
        self.scope = scope
        self.resources = resources
        self.baseImageID = baseImageID
        self.leaseExpiresAt = leaseExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case scope
        case resources
        case baseImageID = "base_image_id"
        case leaseExpiresAt = "lease_expires_at"
    }
}

public struct SandboxWireLeaseRenew: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let scope: SandboxWireScope
    public let leaseExpiresAt: String

    public init(
        operationID: UUID,
        scope: SandboxWireScope,
        leaseExpiresAt: String
    ) {
        self.operationID = operationID
        self.scope = scope
        self.leaseExpiresAt = leaseExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case scope
        case leaseExpiresAt = "lease_expires_at"
    }
}

public struct SandboxWireCommand: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let idempotencyKey: String
    public let scope: SandboxWireScope
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: String?
    public let timeoutSeconds: UInt32

    public init(
        commandID: UUID,
        idempotencyKey: String,
        scope: SandboxWireScope,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeoutSeconds: UInt32
    ) {
        self.commandID = commandID
        self.idempotencyKey = idempotencyKey
        self.scope = scope
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case idempotencyKey = "idempotency_key"
        case scope
        case arguments
        case environment
        case workingDirectory = "working_directory"
        case timeoutSeconds = "timeout_seconds"
    }
}

public struct SandboxWireCommandControl: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let commandID: UUID
    public let scope: SandboxWireScope

    public init(operationID: UUID, commandID: UUID, scope: SandboxWireScope) {
        self.operationID = operationID
        self.commandID = commandID
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case commandID = "command_id"
        case scope
    }
}

public struct SandboxWireOperation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let scope: SandboxWireScope

    public init(operationID: UUID, scope: SandboxWireScope) {
        self.operationID = operationID
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case scope
    }
}

public struct SandboxWireDrain: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let reason: String

    public init(operationID: UUID, reason: String) {
        self.operationID = operationID
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case reason
    }
}
