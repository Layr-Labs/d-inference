import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime
import SandboxRuntimeLume
import SandboxGuestProtocol

protocol SandboxHostCapacityControlling: Sendable {
    func snapshot() throws -> SandboxCapacitySnapshot
    func reserve(
        authoritativeScope: SandboxOperationScope,
        virtualMachineName: String,
        resources: SandboxResourceSpecification,
        bootDiskBytes: UInt64,
        expiresAt: Date
    ) throws -> SandboxCapacityLease
    func renew(
        scope: SandboxOperationScope,
        fencingToken: SandboxFencingToken,
        expiresAt: Date
    ) throws -> SandboxCapacityLease
    func setMode(_ mode: SandboxHostMode) throws -> SandboxCapacitySnapshot
    func resume(
        scope: SandboxOperationScope,
        fencingToken: SandboxFencingToken,
        expiresAt: Date
    ) throws -> SandboxCapacityLease
}

extension SandboxHostCapacityArbiter: SandboxHostCapacityControlling {}

protocol SandboxHostVirtualMachineControlling: Sendable {
    func inspect(
        scope: SandboxOperationScope,
        name: String
    ) async throws -> SandboxVirtualMachineRecord?
    func create(
        scope: SandboxOperationScope,
        specification: SandboxVirtualMachineSpecification
    ) async throws
    func start(
        scope: SandboxOperationScope,
        name: String
    ) async throws
    func execute(
        scope: SandboxOperationScope,
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult
    func file(scope: SandboxOperationScope, name: String, request: GuestRequest) async throws -> GuestResponse
    func stop(
        scope: SandboxOperationScope,
        name: String
    ) async throws
    func deleteAndRelease(
        scope: SandboxOperationScope,
        name: String
    ) async throws
}

extension LumeLeaseFencedVirtualMachineRuntime:
    SandboxHostVirtualMachineControlling
{}

struct SandboxHostIsolationReadiness: Equatable, Sendable {
    let signedGuestControl: Bool
    let networkPolicy: Bool
    let workspaceQuota: Bool

    var permitsJobs: Bool {
        signedGuestControl && networkPolicy && workspaceQuota
    }

    static let unavailable = SandboxHostIsolationReadiness(
        signedGuestControl: false,
        networkPolicy: false,
        workspaceQuota: false
    )
}

