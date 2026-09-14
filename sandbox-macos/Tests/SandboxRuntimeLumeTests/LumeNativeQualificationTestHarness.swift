import Foundation
import SandboxGuestProtocol
import SandboxRuntime
@testable import SandboxRuntimeLume

actor LumeNativeQualificationTestHarness {
    let fault: String
    let firstBoot = UUID(), secondBoot = UUID()
    private var restarted = false
    private var path = "", expectedHash = "", expectedSize: UInt64 = 0
    private var content = Data()
    private var committed = false
    private var ids = Set<UUID>()
    private var commands: [SandboxGuestCommandRequest] = []
    private var events: [String] = []

    init(fault: String = "") { self.fault = fault }
    nonisolated var io: LumeNativeQualificationIO {
        .init(execute: { try await self.execute($0) }, file: { try await self.file($0) }, restart: { try await self.restart() })
    }
    func snapshot() -> (commands: [SandboxGuestCommandRequest], events: [String]) { (commands, events) }

    private func execute(_ request: SandboxGuestCommandRequest) throws -> SandboxGuestCommandResult {
        guard ids.insert(request.idempotencyKey).inserted else { throw HarnessError.duplicateCommand }
        commands.append(request)
        var output: Data
        if request.executable == GuestQualificationProtocol.executable {
            guard request.arguments == [GuestQualificationProtocol.command], request.workingDirectory == "/workspace" else { throw HarnessError.invalidRequest }
            events.append(restarted ? "probe-after" : "probe-before")
            output = fault == "probe-output" ? Data("ok\n".utf8) : GuestQualificationProtocol.successOutput
        } else {
            guard request.executable == "/usr/sbin/sysctl", request.arguments == ["-n", "kern.bootsessionuuid"] else { throw HarnessError.invalidRequest }
            events.append(restarted ? "boot-after" : "boot-before")
            let boot = restarted && fault != "same-boot" ? secondBoot : firstBoot
            output = fault == "invalid-boot" ? Data("unknown\n".utf8) : Data((boot.uuidString + "\n").utf8)
        }
        return .init(exitCode: fault == "exit-code" ? 1 : 0, standardOutput: output,
            standardError: fault == "stderr" ? Data("failure\n".utf8) : Data(),
            standardOutputTruncated: fault == "truncated", timedOut: fault == "timeout")
    }

    private func file(_ request: GuestRequest) throws -> GuestResponse {
        events.append(request.operation.rawValue + (restarted ? "-after" : "-before"))
        var response = GuestResponse(id: fault == "response-id" ? UUID() : request.id, success: true)
        if fault == "requires-stop" { response.requiresVMStop = true }
        if fault == "reported-error" { response.errorCode = "failure" }
        switch request.operation {
        case .mkdir: break
        case .uploadBegin:
            path = try required(request.path); expectedSize = try required(request.size); expectedHash = try required(request.sha256)
        case .uploadChunk:
            guard request.offset == 0 else { throw HarnessError.invalidRequest }
            content = try required(request.data)
        case .uploadCommit: committed = true
        case .download:
            guard committed, request.path == path, request.offset == 0, request.size == expectedSize else { throw HarnessError.invalidRequest }
            let output = restarted && fault == "lost-marker" ? Data("lost".utf8) : content
            response.data = output; response.offset = 0; response.size = expectedSize
            response.sha256 = fault == "download-hash" ? String(repeating: "0", count: 64) : LumeNativeQualificationDriver.digest(output)
            response.version = fault == "missing-revision" ? nil : String(repeating: restarted ? "b" : "a", count: 64)
            return response
        default: throw HarnessError.invalidRequest
        }
        if [.uploadBegin, .uploadChunk, .uploadCommit].contains(request.operation) {
            let offset = UInt64(content.count), state: GuestTransferState = committed ? .committed : .uploading
            response.upload = .init(path: path, size: expectedSize, sha256: expectedHash, offset: offset, state: state)
            response.transferID = request.transferID; response.state = state; response.offset = offset
            response.size = expectedSize; response.sha256 = expectedHash
            if fault == "wrong-transfer" { response.transferID = UUID() }
            if fault == "upload-offset" { response.offset = offset + 1 }
        }
        return response
    }

    private func restart() throws {
        guard committed, !restarted else { throw HarnessError.invalidRequest }
        events.append("restart")
        if fault == "restart-cancelled" { throw CancellationError() }
        restarted = true
    }
    private func required<T>(_ value: T?) throws -> T { guard let value else { throw HarnessError.invalidRequest }; return value }
    private enum HarnessError: Error { case duplicateCommand, invalidRequest }
}
