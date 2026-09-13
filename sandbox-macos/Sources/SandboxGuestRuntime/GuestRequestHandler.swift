import Foundation
import SandboxGuestProtocol

public actor GuestRequestHandler {
    private let executor: any GuestCommandExecuting
    private let workspace: GuestWorkspace
    private var active: (UUID, Task<GuestResponse, Error>)?
    private var executionIDs: Set<UUID> = []
    private var needsVMStop = false
    private var disconnected = false

    public init(executor: any GuestCommandExecuting, workspace: GuestWorkspace) {
        self.executor = executor; self.workspace = workspace
    }

    public func beginSession() throws {
        guard active == nil else { throw GuestProtocolError.busy }
        disconnected = false
    }

    public func handle(_ request: GuestRequest) async -> GuestResponse {
        do { return try await perform(request) }
        catch {
            let code: String
            switch error {
            case GuestProtocolError.busy: code = "guest_busy"
            case GuestProtocolError.invalidPath: code = "invalid_workspace_path"
            case GuestProtocolError.transferConflict: code = "transfer_conflict"
            case GuestProtocolError.fileChanged: code = "file_changed"
            case GuestProtocolError.cleanupUncertain: code = "tenant_cleanup_uncertain"
            case GuestProtocolError.publicationUncertain: code = "upload_publication_uncertain"
            default: code = "invalid_guest_request"
            }
            var result = GuestResponse(id: request.id, success: false, errorCode: code)
            result.requiresVMStop = needsVMStop
            return result
        }
    }

    public func disconnect() async {
        disconnected = true
        active?.1.cancel()
        if let task = active?.1 { _ = try? await task.value }
        // Authenticated host clients reconnect between individual transfer
        // calls. Unlinked, bounded uploads live for this VM-agent lifetime.
    }

    private func perform(_ request: GuestRequest) async throws -> GuestResponse {
        guard !disconnected else { throw GuestProtocolError.disconnected }
        if request.operation == .cancel {
            guard let (id, task) = active, request.transferID == id else {
                throw GuestProtocolError.invalidMessage
            }
            task.cancel()
            let cancelled = try await task.value
            var result = GuestResponse(id: request.id, success: cancelled.requiresVMStop != true)
            result.cancelled = cancelled.cancelled; result.requiresVMStop = cancelled.requiresVMStop
            return result
        }
        guard !needsVMStop else { throw GuestProtocolError.cleanupUncertain }
        if request.operation == .ping { return GuestResponse(id: request.id, success: true) }
        guard active == nil else { throw GuestProtocolError.busy }
        var response = GuestResponse(id: request.id, success: true)
        switch request.operation {
        case .execute:
            guard let command = request.command, executionIDs.count < 4096,
                  executionIDs.insert(request.id).inserted else { throw GuestProtocolError.invalidMessage }
            try command.validate()
            let executor = executor
            let task = Task { try await executor.execute(command, id: request.id) }
            active = (request.id, task)
            defer { active = nil }
            do {
                let result = try await task.value
                needsVMStop = result.requiresVMStop == true
                return result
            } catch { needsVMStop = true; throw error }
        case .mkdir:
            guard let path = request.path else { throw GuestProtocolError.invalidMessage }
            try workspace.makeDirectory(path)
        case .uploadBegin:
            guard let id = request.transferID, let path = request.path,
                  let size = request.size, let digest = request.sha256 else { throw GuestProtocolError.invalidMessage }
            try workspace.begin(id: id, path: path, size: size, sha256: digest)
            response.upload = try workspace.status(id: id)
        case .uploadChunk:
            guard let id = request.transferID, let offset = request.offset, let bytes = request.data
            else { throw GuestProtocolError.invalidMessage }
            try workspace.append(id: id, offset: offset, data: bytes)
            response.upload = try workspace.status(id: id)
        case .uploadCommit:
            guard let id = request.transferID else { throw GuestProtocolError.invalidMessage }
            try workspace.commit(id: id)
            response.upload = try workspace.status(id: id)
        case .uploadAbort:
            guard let id = request.transferID else { throw GuestProtocolError.invalidMessage }
            try workspace.abort(id: id)
            response.upload = try workspace.status(id: id)
        case .uploadStatus:
            guard let id = request.transferID else { throw GuestProtocolError.invalidMessage }
            response.upload = try workspace.status(id: id)
        case .download:
            guard let path = request.path, let offset = request.offset, let size = request.size,
                  size <= UInt64(GuestProtocolLimits.maximumChunkBytes)
            else { throw GuestProtocolError.invalidMessage }
            let downloaded = try workspace.download(path: path, offset: offset, maximumBytes: Int(size), version: request.version)
            response.data = downloaded.data; response.offset = downloaded.offset
            response.size = downloaded.size; response.sha256 = downloaded.sha256
            response.version = downloaded.version
        case .ping, .cancel: throw GuestProtocolError.invalidMessage
        }
        if let upload = response.upload {
            response.transferID = request.transferID
            response.state = upload.state
            response.offset = upload.offset
            response.size = upload.size
            response.sha256 = upload.sha256
        }
        return response
    }
}
