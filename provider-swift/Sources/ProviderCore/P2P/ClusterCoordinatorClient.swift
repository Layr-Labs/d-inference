import Foundation

// MARK: - ClusterPeerKeyInfo

public struct ClusterPeerKeyInfo: Decodable, Sendable {
    public let serial: String
    /// Base64-encoded raw 64-byte P-256 public key (X ∥ Y, no prefix byte).
    public let sePublicKey: String
    public let trustLevel: String
    public let mdaVerified: Bool

    enum CodingKeys: String, CodingKey {
        case serial
        case sePublicKey = "se_public_key"
        case trustLevel  = "trust_level"
        case mdaVerified = "mda_verified"
    }

    /// Decoded raw bytes of the SE public key.
    public var sePublicKeyData: Data? { Data(base64Encoded: sePublicKey) }
}

// MARK: - ClusterCoordinatorClient

/// Thin HTTP client for cluster-related coordinator endpoints.
public enum ClusterCoordinatorClient {

    /// Fetch a peer device's SE public key from the coordinator by hardware serial number.
    ///
    /// - Parameters:
    ///   - serial: The peer's hardware serial number (e.g. from `system_profiler SPHardwareDataType`).
    ///   - coordinatorWSURL: The WebSocket coordinator URL from config (e.g. `wss://api.darkbloom.dev/ws/provider`).
    ///                       Automatically converted to HTTPS for this REST call.
    ///   - authToken: Privy JWT from `darkbloom login` (stored at `~/.darkbloom/auth_token`).
    ///
    /// - Returns: `ClusterPeerKeyInfo` containing the SE public key and attestation metadata.
    /// - Throws: `ClusterCoordinatorError` on network, auth, or not-found failures.
    public static func fetchPeerSEKey(
        serial: String,
        coordinatorWSURL: String,
        authToken: String
    ) async throws -> ClusterPeerKeyInfo {
        let httpBase = httpBase(from: coordinatorWSURL)
        let escaped = serial.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? serial
        guard let url = URL(string: "\(httpBase)/v1/cluster/peer-key?serial=\(escaped)") else {
            throw ClusterCoordinatorError.invalidURL(coordinatorWSURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClusterCoordinatorError.networkError("no HTTP response")
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(ClusterPeerKeyInfo.self, from: data)
        case 401, 403:
            throw ClusterCoordinatorError.unauthorized
        case 404:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClusterCoordinatorError.peerNotFound(serial: serial, detail: body)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClusterCoordinatorError.requestFailed(http.statusCode, body)
        }
    }

    // MARK: - URL helpers

    /// Convert `wss://host:port/path` → `https://host:port` (strips path).
    private static func httpBase(from wsURL: String) -> String {
        var s = wsURL
        if s.hasPrefix("wss://") {
            s = "https://" + s.dropFirst(6)
        } else if s.hasPrefix("ws://") {
            s = "http://" + s.dropFirst(5)
        }
        guard let parsed = URL(string: s),
              let scheme = parsed.scheme,
              let host = parsed.host
        else { return s }
        let port = parsed.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

// MARK: - Errors

public enum ClusterCoordinatorError: Error, CustomStringConvertible {
    case invalidURL(String)
    case networkError(String)
    case unauthorized
    case peerNotFound(serial: String, detail: String)
    case requestFailed(Int, String)

    public var description: String {
        switch self {
        case .invalidURL(let u):
            return "Cannot build coordinator URL from '\(u)'"
        case .networkError(let s):
            return "Network error: \(s)"
        case .unauthorized:
            return "Not authenticated. Run `darkbloom login` first."
        case .peerNotFound(let serial, let detail):
            return "Peer device '\(serial)' not found in coordinator. Ensure it has run `darkbloom serve` at least once and completed attestation. Detail: \(detail)"
        case .requestFailed(let code, let body):
            return "Coordinator returned HTTP \(code): \(body)"
        }
    }
}
