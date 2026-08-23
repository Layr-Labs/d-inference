import Foundation
import SandboxCore

public enum SandboxVirtualMachineState: String, Codable, CaseIterable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case paused
    case installing
    case failed
    case unknown
}

public struct SandboxVirtualMachineRecord: Codable, Equatable, Sendable {
    public let name: String
    public let state: SandboxVirtualMachineState
    public let cpuCount: UInt16?
    public let memoryBytes: UInt64?
    public let diskBytes: UInt64?
    public let guestReady: Bool?

    public init(
        name: String,
        state: SandboxVirtualMachineState,
        cpuCount: UInt16? = nil,
        memoryBytes: UInt64? = nil,
        diskBytes: UInt64? = nil,
        guestReady: Bool? = nil
    ) {
        self.name = name
        self.state = state
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.guestReady = guestReady
    }
}

public struct SandboxVirtualMachineSpecification: Equatable, Sendable {
    public let name: String
    public let resources: SandboxResourceSpecification
    public let imageSource: SandboxVirtualMachineImageSource
    public let diskBytes: UInt64

    public init(
        name: String,
        resources: SandboxResourceSpecification,
        imageSource: SandboxVirtualMachineImageSource,
        diskBytes: UInt64
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SandboxVirtualMachineNamePolicy.isValid(normalizedName) else {
            throw SandboxRuntimeError.invalidName
        }
        let normalizedImageSource = try imageSource.normalized()
        guard diskBytes >= resources.workspaceBytes else {
            throw SandboxRuntimeError.diskSmallerThanWorkspace
        }
        self.name = normalizedName
        self.resources = resources
        self.imageSource = normalizedImageSource
        self.diskBytes = diskBytes
    }

}

public enum SandboxVirtualMachineImageSource: Equatable, Sendable {
    case restoreImage(url: URL, unattendedPreset: String)
    case localTemplate(name: String)

    fileprivate func normalized() throws -> Self {
        switch self {
        case .restoreImage(let url, let unattendedPreset):
            guard url.isFileURL,
                  url.baseURL == nil,
                  !url.path.isEmpty,
                  unattendedPreset == "tahoe"
            else {
                throw SandboxRuntimeError.invalidImageReference
            }
            return .restoreImage(
                url: url.standardizedFileURL,
                unattendedPreset: unattendedPreset
            )
        case .localTemplate(let name):
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SandboxVirtualMachineNamePolicy.isValid(normalized) else {
                throw SandboxRuntimeError.invalidImageReference
            }
            return .localTemplate(name: normalized)
        }
    }
}

public enum SandboxVirtualMachineNamePolicy {
    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...63).contains(bytes.count),
              bytes.first.map(isASCIILowercaseAlphanumeric) == true,
              bytes.last.map(isASCIILowercaseAlphanumeric) == true
        else {
            return false
        }
        return bytes.allSatisfy {
            isASCIILowercaseAlphanumeric($0) || $0 == 45
        }
    }

    private static func isASCIILowercaseAlphanumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte)
            || (48...57).contains(byte)
    }
}

public struct SandboxRuntimeCapabilities: Codable, Equatable, Sendable {
    public let runtime: String
    public let version: String
    public let supportsMacOS: Bool
    public let supportsPause: Bool
    public let supportsSnapshots: Bool

    public init(
        runtime: String,
        version: String,
        supportsMacOS: Bool,
        supportsPause: Bool,
        supportsSnapshots: Bool
    ) {
        self.runtime = runtime
        self.version = version
        self.supportsMacOS = supportsMacOS
        self.supportsPause = supportsPause
        self.supportsSnapshots = supportsSnapshots
    }
}

public enum SandboxRuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName
    case invalidImageReference
    case diskSmallerThanWorkspace
    case executableNotFound(String)
    case operationTimedOut(String)
    case operationInProgress(name: String, operation: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case cleanupFailed(operation: String, primary: String, cleanup: String)
    case malformedOutput(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .invalidName:
            return "VM name must be 1-63 lowercase ASCII alphanumeric-or-hyphen characters"
        case .invalidImageReference:
            return "VM image reference must not be empty"
        case .diskSmallerThanWorkspace:
            return "VM disk must be at least as large as the workspace quota"
        case .executableNotFound(let executable):
            return "required runtime executable not found: \(executable)"
        case .operationTimedOut(let operation):
            return "runtime operation timed out: \(operation)"
        case .operationInProgress(let name, let operation):
            return "VM \(name) already has an active \(operation) operation"
        case .commandFailed(let command, let exitCode, let stderr):
            return "runtime command failed (\(exitCode)): \(command): \(stderr)"
        case .cleanupFailed(let operation, let primary, let cleanup):
            return "\(operation) failed (\(primary)); cleanup also failed (\(cleanup))"
        case .malformedOutput(let detail):
            return "runtime returned malformed output: \(detail)"
        case .unsupported(let detail):
            return "runtime operation is unsupported: \(detail)"
        }
    }
}

public protocol SandboxVirtualMachineRuntime: Sendable {
    func capabilities() async throws -> SandboxRuntimeCapabilities
    func list() async throws -> [SandboxVirtualMachineRecord]
    func inspect(name: String) async throws -> SandboxVirtualMachineRecord?
    func create(_ specification: SandboxVirtualMachineSpecification) async throws
    func start(name: String) async throws
    func stop(name: String) async throws
    func delete(name: String) async throws
}
