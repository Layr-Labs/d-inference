import Foundation
import SandboxGuestProtocol

/// Binary plist avoids JSON's sixfold control-character escaping expansion in
/// the worker argv. The cap leaves macOS ARG_MAX room for argv and environment.
enum GuestWorkerPayload {
    static let maximumDecodedBytes = 131_072
    static let maximumEncodedBytes = ((maximumDecodedBytes + 2) / 3) * 4

    static func encode(_ command: GuestCommand) throws -> String {
        try command.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(command)
        guard data.count <= maximumDecodedBytes else { throw GuestProtocolError.invalidMessage }
        return data.base64EncodedString()
    }

    static func decode(_ encoded: String) throws -> GuestCommand {
        guard encoded.utf8.count <= maximumEncodedBytes,
              let bytes = Data(base64Encoded: encoded), bytes.count <= maximumDecodedBytes,
              bytes.starts(with: Data("bplist00".utf8)) else { throw GuestProtocolError.invalidMessage }
        let command = try PropertyListDecoder().decode(GuestCommand.self, from: bytes)
        try command.validate()
        return command
    }
}
