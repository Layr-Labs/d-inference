/// DeviceAuth -- RFC 8628 device code flow for linking a provider to a Darkbloom account.
///
/// The flow:
/// 1. Provider POSTs to `/v1/device/code` to get a device_code, user_code, and verification_uri.
/// 2. User opens the verification_uri in their browser and enters the user_code.
/// 3. Provider polls `/v1/device/token` until the user approves (or the code expires).
/// 4. On approval, the coordinator returns an auth token which is saved to `~/.darkbloom/auth_token`.
///
/// Mirrors the Rust implementation in `provider/src/main.rs` (cmd_login / cmd_logout).

import Foundation

// MARK: - Token Storage

public enum AuthTokenStore: Sendable {

    /// Path to the stored auth token: ~/.darkbloom/auth_token
    public static func tokenPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom")
            .appendingPathComponent("auth_token")
    }

    /// Load the saved auth token, if any.
    public static func load() -> String? {
        let path = tokenPath()
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Save an auth token to disk with restricted permissions (owner read/write only).
    public static func save(_ token: String) throws {
        let path = tokenPath()
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        try token.write(to: path, atomically: true, encoding: .utf8)

        // Restrict to owner read/write (0600).
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o600
        ]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path.path)
    }

    /// Delete the auth token file.
    public static func delete() throws {
        let path = tokenPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

// MARK: - Device Code Flow

/// Response from POST /v1/device/code
private struct DeviceCodeResponse: Decodable, Sendable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int
}

/// Response from POST /v1/device/token
private struct DeviceTokenResponse: Decodable, Sendable {
    let status: String?
    let token: String?
    let error: TokenError?

    struct TokenError: Decodable, Sendable {
        let message: String?
    }
}

public enum DeviceAuthError: Error, CustomStringConvertible, Sendable {
    case alreadyLoggedIn(tokenPrefix: String)
    case coordinatorUnreachable(String)
    case deviceCodeRequestFailed(String)
    case deviceCodeExpired
    case authorizationFailed(String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .alreadyLoggedIn(let prefix):
            return "Already logged in (token: \(prefix)...). Run 'darkbloom logout' first to unlink."
        case .coordinatorUnreachable(let detail):
            return "Failed to reach coordinator: \(detail)"
        case .deviceCodeRequestFailed(let detail):
            return "Failed to get device code: \(detail)"
        case .deviceCodeExpired:
            return "Device code expired. Run 'darkbloom login' again."
        case .authorizationFailed(let detail):
            return "Authorization failed: \(detail)"
        case .invalidResponse(let detail):
            return "Invalid response from coordinator: \(detail)"
        }
    }
}

/// Convert a coordinator WebSocket URL to an HTTP base URL.
///
/// Examples:
///   - `wss://api.darkbloom.dev/ws/provider` -> `https://api.darkbloom.dev`
///   - `ws://localhost:8080/ws/provider` -> `http://localhost:8080`
public func coordinatorHTTPBase(_ wsURL: String) -> String {
    wsURL
        .replacingOccurrences(of: "wss://", with: "https://")
        .replacingOccurrences(of: "ws://", with: "http://")
        .replacingOccurrences(of: "/ws/provider", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

/// Run the device code login flow.
///
/// Posts to the coordinator to get a device code, displays the verification URL
/// and user code, then polls until the user authorizes or the code expires.
///
/// - Parameters:
///   - coordinatorURL: The coordinator base HTTP URL (not the WebSocket URL).
///   - onDisplayCode: Callback to display the user code and verification URL.
///     Called once when the device code is received. The caller should print
///     these to the terminal. Parameters: (userCode, verificationURI, expiresInSeconds).
///   - onPollTick: Optional callback on each poll iteration (e.g., to print a dot).
/// - Returns: The auth token string on success.
/// - Throws: `DeviceAuthError` on failure.
@discardableResult
public func performDeviceCodeLogin(
    coordinatorURL: String,
    onDisplayCode: @Sendable (String, String, Int) -> Void,
    onPollTick: (@Sendable () -> Void)? = nil
) async throws -> String {
    // Check if already logged in.
    if let existingToken = AuthTokenStore.load() {
        let prefix = String(existingToken.prefix(min(20, existingToken.count)))
        throw DeviceAuthError.alreadyLoggedIn(tokenPrefix: prefix)
    }

    let baseURL = coordinatorHTTPBase(coordinatorURL)

    // Step 1: Request a device code.
    let codeURL = URL(string: "\(baseURL)/v1/device/code")!
    var codeRequest = URLRequest(url: codeURL)
    codeRequest.httpMethod = "POST"
    codeRequest.timeoutInterval = 10

    let codeData: Data
    let codeResponse: URLResponse
    do {
        (codeData, codeResponse) = try await URLSession.shared.data(for: codeRequest)
    } catch {
        throw DeviceAuthError.coordinatorUnreachable(error.localizedDescription)
    }

    guard let httpResponse = codeResponse as? HTTPURLResponse else {
        throw DeviceAuthError.invalidResponse("non-HTTP response")
    }
    guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
        let body = String(data: codeData, encoding: .utf8) ?? ""
        throw DeviceAuthError.deviceCodeRequestFailed(body)
    }

    let dc: DeviceCodeResponse
    do {
        dc = try JSONDecoder().decode(DeviceCodeResponse.self, from: codeData)
    } catch {
        throw DeviceAuthError.invalidResponse("could not decode device code response: \(error)")
    }

    // Display the code to the user.
    onDisplayCode(dc.user_code, dc.verification_uri, dc.expires_in)

    // Try to open the browser automatically.
    let openProcess = Process()
    openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    openProcess.arguments = [dc.verification_uri]
    openProcess.standardOutput = FileHandle.nullDevice
    openProcess.standardError = FileHandle.nullDevice
    _ = try? openProcess.run()

    // Step 2: Poll for authorization.
    let tokenURL = URL(string: "\(baseURL)/v1/device/token")!
    let pollInterval = max(dc.interval, 1) // At least 1 second
    let deadline = Date().addingTimeInterval(TimeInterval(dc.expires_in))

    while Date() < deadline {
        try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)

        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokenRequest.timeoutInterval = 10

        let body = try JSONSerialization.data(
            withJSONObject: ["device_code": dc.device_code]
        )
        tokenRequest.httpBody = body

        let tokenData: Data
        do {
            (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
        } catch {
            // Network error -- retry on next tick.
            onPollTick?()
            continue
        }

        let tokenResp: DeviceTokenResponse
        do {
            tokenResp = try JSONDecoder().decode(DeviceTokenResponse.self, from: tokenData)
        } catch {
            // Malformed response -- retry.
            onPollTick?()
            continue
        }

        switch tokenResp.status ?? "" {
        case "authorization_pending":
            onPollTick?()
            continue

        case "authorized":
            guard let token = tokenResp.token, !token.isEmpty else {
                throw DeviceAuthError.invalidResponse("authorized but no token in response")
            }
            try AuthTokenStore.save(token)
            return token

        default:
            // expired or error
            let message = tokenResp.error?.message ?? "Device code expired or invalid"
            throw DeviceAuthError.authorizationFailed(message)
        }
    }

    throw DeviceAuthError.deviceCodeExpired
}
