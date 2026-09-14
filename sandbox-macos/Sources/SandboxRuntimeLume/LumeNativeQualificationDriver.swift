import CryptoKit
import Foundation
import SandboxCore
import SandboxGuestProtocol
import SandboxRuntime

/// The production caller supplies only normal fenced runtime operations. The
/// closures permit deterministic failure tests without pretending to boot a VM.
struct LumeNativeQualificationIO: Sendable {
    let execute: @Sendable (SandboxGuestCommandRequest) async throws -> SandboxGuestCommandResult
    let file: @Sendable (GuestRequest) async throws -> GuestResponse
    let restart: @Sendable () async throws -> Void
}

struct LumeNativeQualificationObservations: Equatable, Sendable {
    let initialBootID: UUID
    let restartedBootID: UUID
    let markerSHA256: String
}

struct LumeNativeQualificationDriver: Sendable {
    let qualificationID: UUID
    let cloneInstallationID: UUID
    let io: LumeNativeQualificationIO

    func run() async throws -> LumeNativeQualificationObservations {
        try Task.checkCancellation()
        try await probe("probe-before")
        let initial = try await bootID("boot-before")
        let directory = "qualification-" + qualificationID.uuidString.lowercased()
        let path = directory + "/roundtrip.marker"
        let bytes = GuestQualificationProtocol.marker(qualificationID: qualificationID, cloneInstallationID: cloneInstallationID)
        let hash = Self.digest(bytes), transferID = identifier("marker-transfer")
        _ = try await send(.init(id: identifier("mkdir"), operation: .mkdir, path: directory))
        let begin = try await send(.init(id: identifier("upload-begin"), operation: .uploadBegin,
            transferID: transferID, path: path, size: UInt64(bytes.count), sha256: hash))
        try requireUpload(begin, transferID: transferID, path: path, bytes: bytes, state: .uploading, offset: 0)
        let chunk = try await send(.init(id: identifier("upload-chunk"), operation: .uploadChunk,
            transferID: transferID, offset: 0, data: bytes))
        try requireUpload(chunk, transferID: transferID, path: path, bytes: bytes, state: .uploading, offset: UInt64(bytes.count))
        let commit = try await send(.init(id: identifier("upload-commit"), operation: .uploadCommit, transferID: transferID))
        try requireUpload(commit, transferID: transferID, path: path, bytes: bytes, state: .committed, offset: UInt64(bytes.count))
        try await download("download-before", path: path, bytes: bytes)
        try Task.checkCancellation()
        try await io.restart()
        try Task.checkCancellation()
        let restarted = try await bootID("boot-after")
        guard restarted != initial else { throw Self.failure("cold boot did not change the kernel boot identity") }
        try await probe("probe-after")
        try await download("download-after", path: path, bytes: bytes)
        return .init(initialBootID: initial, restartedBootID: restarted, markerSHA256: hash)
    }

    private func probe(_ step: String) async throws {
        let result = try await io.execute(.init(idempotencyKey: identifier(step),
            executable: GuestQualificationProtocol.executable, arguments: [GuestQualificationProtocol.command],
            workingDirectory: "/workspace", timeoutSeconds: 30))
        try Self.requireCommand(result)
        guard result.standardOutput == GuestQualificationProtocol.successOutput else { throw Self.failure("tenant probe output did not match") }
    }

    private func bootID(_ step: String) async throws -> UUID {
        let result = try await io.execute(.init(idempotencyKey: identifier(step), executable: "/usr/sbin/sysctl",
            arguments: ["-n", "kern.bootsessionuuid"], workingDirectory: "/workspace", timeoutSeconds: 10))
        try Self.requireCommand(result)
        guard result.standardOutput.count <= 64,
              let id = UUID(uuidString: String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Self.failure("kernel boot identity was unavailable")
        }
        return id
    }

    private func send(_ request: GuestRequest) async throws -> GuestResponse {
        try Task.checkCancellation()
        let result = try await io.file(request)
        guard result.id == request.id, result.success, result.errorCode == nil, result.requiresVMStop != true else { throw Self.failure("workspace request or cleanup failed") }
        return result
    }

    private func requireUpload(_ result: GuestResponse, transferID: UUID, path: String, bytes: Data, state: GuestTransferState, offset: UInt64) throws {
        guard let upload = result.upload, upload.path == path, upload.size == UInt64(bytes.count),
              upload.sha256 == Self.digest(bytes), upload.state == state, upload.offset == offset,
              result.transferID == transferID, result.state == state, result.offset == offset,
              result.size == upload.size, result.sha256 == upload.sha256 else {
            throw Self.failure("workspace upload acknowledgment did not match")
        }
    }

    private func download(_ step: String, path: String, bytes: Data) async throws {
        let result = try await send(.init(id: identifier(step), operation: .download, path: path, offset: 0, size: UInt64(bytes.count)))
        guard result.data == bytes, result.offset == 0, result.size == UInt64(bytes.count),
              result.sha256 == Self.digest(bytes), let version = result.version, LumeInstalledCandidateCheckpoint.isDigest(version) else {
            throw Self.failure("workspace bytes, digest, size or revision did not match")
        }
        // A revision may change across a remount. Compare persisted bytes/hash;
        // do not confuse a mount-dependent revision with the content itself.
    }

    private func identifier(_ step: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("qualification-v1:" + qualificationID.uuidString.lowercased()
            + ":" + cloneInstallationID.uuidString.lowercased() + ":" + step).utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func requireCommand(_ result: SandboxGuestCommandResult) throws {
        guard result.exitCode == 0, !result.timedOut, !result.standardOutputTruncated,
              !result.standardErrorTruncated, result.standardError.isEmpty else { throw failure("native command failed or output was incomplete") }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ reason: String) -> SandboxRuntimeError { .unsupported("native qualification: " + reason) }
}
