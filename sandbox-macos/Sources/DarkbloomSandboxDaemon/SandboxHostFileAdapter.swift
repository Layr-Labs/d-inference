import Foundation
import SandboxCore
import SandboxGuestProtocol
import SandboxHostControl
import SandboxRuntime

extension SandboxHostVirtualMachineControlling {
    func file(scope: SandboxOperationScope, name: String,
              request: GuestRequest) async throws -> GuestResponse {
        throw GuestProtocolError.unavailable
    }
}

extension SandboxHostProductionAdapter {
    func admitFile(_ payload: SandboxWireFileOperation) -> SandboxHostControlAdmission {
        SandboxHostControlAdmission {
            do {
                guard self.isolationReadiness.permitsJobs,
                      SandboxFileWireValidation.validate(payload) else { throw GuestProtocolError.invalidMessage }
                let request = GuestRequest(id: payload.requestID, operation: Self.guestOperation(payload.operation),
                    transferID: payload.transferID, path: payload.path, offset: payload.offset,
                    size: payload.size, data: payload.data, sha256: payload.sha256, version: payload.version)
                let reply = try await self.runtime.file(scope: payload.scope.operationScope,
                    name: Self.virtualMachineName(for: payload.scope), request: request)
                guard reply.id == payload.requestID, reply.requiresVMStop != true else {
                    throw GuestProtocolError.cleanupUncertain
                }
                if !reply.success {
                    return .file(SandboxWireFileResult(requestID: payload.requestID, scope: payload.scope,
                        operation: payload.operation, success: false, errorCode: reply.errorCode ?? "guest_operation_failed",
                        transferID: payload.transferID))
                }
                if payload.operation == .uploadAbort {
                    guard reply.state == .aborted else {
                        return .file(SandboxWireFileResult(requestID: payload.requestID, scope: payload.scope,
                            operation: payload.operation, success: false, errorCode: "upload_already_committed",
                            transferID: payload.transferID))
                    }
                    return .file(SandboxWireFileResult(requestID: payload.requestID, scope: payload.scope,
                        operation: payload.operation, success: true, transferID: reply.transferID,
                        state: reply.state?.rawValue))
                }
                return .file(SandboxWireFileResult(requestID: payload.requestID, scope: payload.scope,
                    operation: payload.operation, success: reply.success, errorCode: reply.errorCode,
                    transferID: reply.transferID, state: reply.state?.rawValue, offset: reply.offset,
                    size: reply.size, sha256: reply.sha256, data: reply.data, version: reply.version))
            } catch {
                return .file(SandboxWireFileResult(requestID: payload.requestID, scope: payload.scope,
                    operation: payload.operation, success: false, errorCode: Self.errorCode(error)))
            }
        }
    }

    private static func guestOperation(_ operation: SandboxWireFileOperationKind) -> GuestRequest.Operation {
        switch operation {
        case .uploadBegin: .uploadBegin
        case .uploadChunk: .uploadChunk
        case .uploadStatus: .uploadStatus
        case .uploadCommit: .uploadCommit
        case .uploadAbort: .uploadAbort
        case .download: .download
        case .mkdir: .mkdir
        }
    }
}
