import Foundation
import SandboxRuntime

enum LumeGuestCommandEnvelope {
    static let magic = "darkbloom_guest_result"
    static let schemaVersion: UInt16 = 1
    static let maximumStreamBytes = 1_048_576
    static let maximumEnvelopeBytes =
        2 * (((maximumStreamBytes + 2) / 3) * 4) + 1_024
}

enum LumeGuestCommandResultDecoder {
    static func decode(_ data: Data) throws -> SandboxGuestCommandResult {
        guard data.count <= LumeGuestCommandEnvelope.maximumEnvelopeBytes else {
            throw malformed()
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw malformed()
        }
        guard envelope.magic == LumeGuestCommandEnvelope.magic,
              envelope.schemaVersion == LumeGuestCommandEnvelope.schemaVersion,
              envelope.standardOutput.count == envelope.standardOutputLength,
              envelope.standardError.count == envelope.standardErrorLength,
              envelope.standardOutput.count
                  <= LumeGuestCommandEnvelope.maximumStreamBytes,
              envelope.standardError.count
                  <= LumeGuestCommandEnvelope.maximumStreamBytes
        else {
            throw malformed()
        }
        return SandboxGuestCommandResult(
            exitCode: envelope.exitCode,
            standardOutput: envelope.standardOutput,
            standardError: envelope.standardError,
            standardOutputTruncated: envelope.standardOutputTruncated,
            standardErrorTruncated: envelope.standardErrorTruncated
        )
    }

    private static func malformed() -> SandboxRuntimeError {
        .malformedOutput("Lume guest-command result envelope is invalid")
    }

    private struct Envelope: Decodable {
        let magic: String
        let schemaVersion: UInt16
        let exitCode: Int32
        let standardOutputLength: Int
        let standardErrorLength: Int
        let standardOutputTruncated: Bool
        let standardErrorTruncated: Bool
        let standardOutput: Data
        let standardError: Data

        private enum CodingKeys: String, CodingKey {
            case magic
            case schemaVersion = "schema_version"
            case exitCode = "exit_code"
            case standardOutputLength = "stdout_length"
            case standardErrorLength = "stderr_length"
            case standardOutputTruncated = "stdout_truncated"
            case standardErrorTruncated = "stderr_truncated"
            case standardOutput = "stdout_base64"
            case standardError = "stderr_base64"
        }
    }
}
