import Foundation

/// The `hold.v1` contract on the add-on socket: one newline-terminated JSON
/// object per request (at most 8 KiB before the newline) and one response
/// line per request. Responses carry exactly the documented keys.
enum AddonIPC {
    static let version = 1
    static let maximumMessageBytes = 8 * 1024
    static let capabilities = ["hold.v1"]

    enum ErrorCode: String, Error, Sendable, Equatable {
        case unauthorized
        case unsupportedVersion = "unsupported_version"
        case invalidRequest = "invalid_request"
        case notFound = "not_found"
        case unavailable
    }

    enum Request: Sendable, Equatable {
        case hello
        case hold(addon: String, vmBytes: UInt64, leaseSeconds: Int)
        case status(holdID: String)
        case renew(holdID: String, leaseSeconds: Int)
        case release(holdID: String)
    }

    /// `released` and `expired` describe a recently ended hold.
    enum HoldState: String, Sendable, Equatable { case draining, held, released, expired }

    enum Response: Sendable, Equatable {
        case hello(providerVersion: String)
        case hold(holdID: String, state: HoldState, sinceMs: Int64, leaseExpiresAtMs: Int64)
        case status(state: HoldState, sinceMs: Int64, leaseExpiresAtMs: Int64)
        case renewed(state: HoldState, leaseExpiresAtMs: Int64)
        case released
        case failure(ErrorCode)
    }

    // MARK: - Parsing

    private struct Envelope: Decodable {
        let v: Int?
        let op: String?
    }

    private struct HoldFields: Decodable {
        let addon: String
        let vmBytes: UInt64
        let leaseSeconds: Int
        enum CodingKeys: String, CodingKey { case addon, vmBytes = "vm_bytes", leaseSeconds = "lease_seconds" }
    }

    private struct HoldReference: Decodable {
        let holdID: String
        let leaseSeconds: Int?
        enum CodingKeys: String, CodingKey { case holdID = "hold_id", leaseSeconds = "lease_seconds" }
    }

    /// Unknown keys are ignored. A wrong `v` is reported before the operation
    /// so a newer client learns the version mismatch first.
    static func parse(_ line: Data) -> Result<Request, ErrorCode> {
        guard line.count <= maximumMessageBytes else { return .failure(.invalidRequest) }
        let decoder = JSONDecoder()
        guard (try? JSONSerialization.jsonObject(with: line)) is [String: Any],
              let envelope = try? decoder.decode(Envelope.self, from: line),
              let version = envelope.v else { return .failure(.invalidRequest) }
        guard version == Self.version else { return .failure(.unsupportedVersion) }
        switch envelope.op {
        case "hello":
            return .success(.hello)
        case "hold":
            guard let fields = try? decoder.decode(HoldFields.self, from: line),
                  isBundleIdentifier(fields.addon),
                  AddonHold.leaseSeconds.contains(fields.leaseSeconds) else { return .failure(.invalidRequest) }
            return .success(.hold(addon: fields.addon, vmBytes: fields.vmBytes, leaseSeconds: fields.leaseSeconds))
        case "status", "release":
            guard let reference = try? decoder.decode(HoldReference.self, from: line),
                  isHoldID(reference.holdID) else { return .failure(.invalidRequest) }
            return .success(envelope.op == "status" ? .status(holdID: reference.holdID) : .release(holdID: reference.holdID))
        case "renew":
            guard let reference = try? decoder.decode(HoldReference.self, from: line),
                  isHoldID(reference.holdID), let lease = reference.leaseSeconds,
                  AddonHold.leaseSeconds.contains(lease) else { return .failure(.invalidRequest) }
            return .success(.renew(holdID: reference.holdID, leaseSeconds: lease))
        default:
            return .failure(.invalidRequest)
        }
    }

    /// Reverse-DNS code-signing identifiers only; the value must also match
    /// the peer's verified signing identifier.
    static func isBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.first != "." && value.last != "."
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    private static func isHoldID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
    }

    // MARK: - Encoding

    private struct HelloBody: Encodable {
        let v = AddonIPC.version, ok = true
        let capabilities = AddonIPC.capabilities
        let providerVersion: String
        enum CodingKeys: String, CodingKey { case v, ok, capabilities, providerVersion = "provider_version" }
    }

    private struct HoldBody: Encodable {
        let v = AddonIPC.version, ok = true
        let holdID: String, state: String, sinceMs: Int64, leaseExpiresAtMs: Int64
        enum CodingKeys: String, CodingKey {
            case v, ok, state, holdID = "hold_id", sinceMs = "since_ms", leaseExpiresAtMs = "lease_expires_at_ms"
        }
    }

    private struct StatusBody: Encodable {
        let v = AddonIPC.version, ok = true
        let state: String, sinceMs: Int64, leaseExpiresAtMs: Int64
        enum CodingKeys: String, CodingKey {
            case v, ok, state, sinceMs = "since_ms", leaseExpiresAtMs = "lease_expires_at_ms"
        }
    }

    private struct RenewBody: Encodable {
        let v = AddonIPC.version, ok = true
        let state: String, leaseExpiresAtMs: Int64
        enum CodingKeys: String, CodingKey { case v, ok, state, leaseExpiresAtMs = "lease_expires_at_ms" }
    }

    private struct ReleaseBody: Encodable {
        let v = AddonIPC.version, ok = true, state = HoldState.released.rawValue
    }

    private struct ErrorBody: Encodable {
        let v = AddonIPC.version, ok = false
        let error: String
    }

    /// One response line, newline included.
    static func encode(_ response: Response) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body: Data?
        switch response {
        case .hello(let version):
            body = try? encoder.encode(HelloBody(providerVersion: version))
        case .hold(let id, let state, let since, let expires):
            body = try? encoder.encode(HoldBody(holdID: id, state: state.rawValue, sinceMs: since, leaseExpiresAtMs: expires))
        case .status(let state, let since, let expires):
            body = try? encoder.encode(StatusBody(state: state.rawValue, sinceMs: since, leaseExpiresAtMs: expires))
        case .renewed(let state, let expires):
            body = try? encoder.encode(RenewBody(state: state.rawValue, leaseExpiresAtMs: expires))
        case .released:
            body = try? encoder.encode(ReleaseBody())
        case .failure(let code):
            body = try? encoder.encode(ErrorBody(error: code.rawValue))
        }
        var line = body ?? Data(#"{"error":"unavailable","ok":false,"v":1}"#.utf8)
        line.append(0x0A)
        return line
    }
}
