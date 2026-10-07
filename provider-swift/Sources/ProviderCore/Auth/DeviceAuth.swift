/// DeviceAuth -- RFC 8628 device code flow for linking a provider to a Darkbloom account.
///
/// The flow:
/// 1. Provider POSTs to `/v1/device/code` to get a device_code, user_code, and verification_uri.
/// 2. User opens the verification_uri in their browser and enters the user_code.
/// 3. Provider polls `/v1/device/token` until the user approves (or the code expires).
/// 4. On approval, the coordinator returns an auth token which is saved to `~/.darkbloom/auth_token`.

import Foundation

// MARK: - Token Storage

public enum AuthTokenStore: Sendable {

    /// Path to the canonical stored auth token. Test harnesses can override this with
    /// DARKBLOOM_AUTH_TOKEN_PATH to avoid touching the user's login state.
    public static func tokenPath() -> URL {
        if let override = tokenPathOverride() {
            return URL(fileURLWithPath: override)
        }
        return canonicalTokenPath(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func canonicalTokenPath(home: URL) -> URL {
        home.appendingPathComponent(".darkbloom").appendingPathComponent("auth_token")
    }

    private static func tokenPathOverride() -> String? {
        guard let override = ProcessInfo.processInfo.environment["DARKBLOOM_AUTH_TOKEN_PATH"], !override.isEmpty else {
            return nil
        }
        return override
    }

    /// Load the saved auth token, if any.
    public static func load() -> String? {
        readToken(from: tokenPath())
    }

    /// Read another user's credentials without writing auth files (the
    /// invoking user of `sudo darkbloom report`). An explicit override wins.
    public static func loadReadOnly(home: URL, overridePath: String? = nil) -> String? {
        if let overridePath, !overridePath.isEmpty {
            return readToken(from: URL(fileURLWithPath: overridePath))
        }
        return readToken(from: canonicalTokenPath(home: home))
    }

    private static func readToken(from path: URL) -> String? {
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
///   - automaticallyOpenBrowser: Open verification immediately by default. Desktop UI
///     disables this so the user can read the code before choosing Open sign-in.
/// - Returns: The auth token string on success.
/// - Throws: `DeviceAuthError` on failure.
@discardableResult
public func performDeviceCodeLogin(
    coordinatorURL: String,
    onDisplayCode: @Sendable (String, String, Int) -> Void,
    onPollTick: (@Sendable () -> Void)? = nil,
    purpose: String? = nil,
    allowLegacyAccountFlow: Bool = false,
    automaticallyOpenBrowser: Bool = true
) async throws -> String {
    try await DeviceLoginClient().login(coordinatorURL: coordinatorURL, onDisplayCode: onDisplayCode,
      onPollTick: onPollTick, purpose: purpose, allowLegacyAccountFlow: allowLegacyAccountFlow,
      automaticallyOpenBrowser: automaticallyOpenBrowser)
}
