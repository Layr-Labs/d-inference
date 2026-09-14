import Foundation
import SandboxCore
import SandboxRuntime

/// Never removed or retried. A crash before spawn still consumes this attempt;
/// recovery may stop/observe it, but may not start the installer a second time.
enum LumeInstallerBootClaim {
    static let fileName = LumeInstalledCandidateCheckpoint.bootClaimFileName
    private static let maximumBytes = 32 * 1024

    static func requireAbsent(name: String, storage: URL) throws {
        guard try LumeVirtualMachineStartIntentAuthority.readIfPresent(name: name, fileName: fileName,
            maximumBytes: maximumBytes, in: storage) == nil else {
            throw SandboxRuntimeError.unsupported("accountless installer attempt requires its recovery path")
        }
    }

    static func existsMatching(_ request: LumeInstallerBootRequest, name: String, storage: URL) throws -> Bool {
        guard let bytes = try LumeVirtualMachineStartIntentAuthority.readIfPresent(name: name,
            fileName: fileName, maximumBytes: maximumBytes, in: storage) else { return false }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(bytes)
        guard bytes == (try encoded(request)) else { throw SandboxRuntimeError.unsupported("installer boot was claimed by a different permit") }
        return true
    }

    static func publish(_ request: LumeInstallerBootRequest, name: String, storage: URL) throws {
        try LumeVirtualMachineStartIntentAuthority.publish(encoded(request), name: name,
            fileName: fileName, maximumBytes: maximumBytes, in: storage)
        guard try existsMatching(request, name: name, storage: storage) else {
            throw SandboxRuntimeError.unsupported("installer boot claim publication is unproven")
        }
    }

    private static func encoded(_ request: LumeInstallerBootRequest) throws -> Data {
        let candidate = try request.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Record(schemaVersion: 1, bootstrapAttemptID: candidate.bootstrapAttemptID,
            installationID: candidate.source.installationID, lifecycle: "broker_eof_v1", request: request))
    }
    private struct Record: Codable {
        let schemaVersion: Int; let bootstrapAttemptID: UUID; let installationID: UUID
        let lifecycle: String; let request: LumeInstallerBootRequest
    }
}
