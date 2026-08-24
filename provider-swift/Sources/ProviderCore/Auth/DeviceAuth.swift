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
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom")
            .appendingPathComponent("auth_token")
    }

    private static func tokenPathOverride() -> String? {
        guard let override = ProcessInfo.processInfo.environment["DARKBLOOM_AUTH_TOKEN_PATH"], !override.isEmpty else {
            return nil
        }
        return override
    }

    static func legacyTokenPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first

        var paths = [
            home
                .appendingPathComponent(".config")
                .appendingPathComponent("eigeninference")
                .appendingPathComponent("auth_token"),
        ]
        if let appSupport {
            paths.append(
                appSupport
                    .appendingPathComponent("eigeninference")
                    .appendingPathComponent("auth_token")
            )
        }
        return paths
    }

    /// Load the saved auth token, if any.
    public static func load() -> String? {
        load(canonicalPath: tokenPath(), legacyPaths: tokenPathOverride() == nil ? legacyTokenPaths() : [])
    }

    static func load(canonicalPath: URL, legacyPaths: [URL]) -> String? {
        if let token = readToken(from: canonicalPath) {
            return token
        }

        for legacyPath in legacyPaths where legacyPath != canonicalPath {
            if let token = readToken(from: legacyPath) {
                try? save(token, to: canonicalPath)
                return token
            }
        }
        return nil
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
        try save(token, to: tokenPath())
    }

    private static func save(_ token: String, to path: URL) throws {
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
        try delete(canonicalPath: tokenPath(), legacyPaths: tokenPathOverride() == nil ? legacyTokenPaths() : [])
    }

    static func delete(canonicalPath: URL, legacyPaths: [URL]) throws {
        var seen = Set<String>()
        for path in [canonicalPath] + legacyPaths where seen.insert(path.path).inserted {
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
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
    /// The coordinator account this machine was linked to (`account_id` on the
    /// wire). Present on a successful authorization; persisted locally so
    /// `darkbloom earnings` and the daemon-state identity block can address
    /// payouts without re-resolving the auth token server-side.
    let accountID: String?
    let error: TokenError?

    enum CodingKeys: String, CodingKey {
        case status
        case token
        case accountID = "account_id"
        case error
    }

    struct TokenError: Decodable, Sendable {
        let message: String?
    }
}

/// Live progress of an RFC 8628 device-code login.
///
/// Emitted at the seam where the flow runs (`performDeviceCodeLogin`) so UI
/// wrappers can consume machine-readable state instead of scraping terminal
/// output. `darkbloom login --json` serializes these as NDJSON on stdout (one
/// JSON object per line) for the Darkbloom macOS app's onboarding; the decoder
/// on the app side lives in
/// `Sources/DarkbloomApp/Services/AccountLinkCLI.swift` and mirrors this enum
/// case-for-case. Keep both sides in sync when changing the wire shape.
///
/// Delivery contract: `.code` fires at most once per attempt; exactly one
/// terminal event (`.linked` or `.error`) fires before `performDeviceCodeLogin`
/// returns or throws. The polling loop always terminates — on approval,
/// coordinator denial, or expiry — so a consumer's event stream never hangs.
public enum DeviceLoginEvent: Sendable, Equatable {
    /// A fresh device code was issued by the coordinator. `expiresIn` is in
    /// seconds; the login attempt gives up (`.error`) once it lapses.
    case code(userCode: String, verificationURI: String, expiresIn: Int)
    /// The user approved the code and the auth token was saved.
    case linked
    /// The attempt ended without linking (expired, denied, unreachable, or
    /// malformed response). `message` is the terminal error's description.
    case error(message: String)

    /// Whether this event ends the attempt's event stream.
    public var isTerminal: Bool {
        switch self {
        case .code: return false
        case .linked, .error: return true
        }
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
///   - openBrowser: Try to open the verification URL in the system browser
///     (`/usr/bin/open`). UI wrappers pass false — they deeplink the URL
///     themselves once they receive the `.code` event.
///   - onEvent: Optional machine-readable progress seam (see
///     `DeviceLoginEvent`). Emits `.code` once, then exactly one terminal
///     `.linked`/`.error` before this function returns or throws — a consumer
///     keying off terminal events never hangs, because the poll loop below is
///     bounded by the coordinator-provided expiry.
/// - Returns: The auth token string on success.
/// - Throws: `DeviceAuthError` on failure.
@discardableResult
public func performDeviceCodeLogin(
    coordinatorURL: String,
    onDisplayCode: @Sendable (String, String, Int) -> Void,
    onPollTick: (@Sendable () -> Void)? = nil,
    openBrowser: Bool = true,
    onEvent: (@Sendable (DeviceLoginEvent) -> Void)? = nil
) async throws -> String {
    do {
        let token = try await runDeviceCodeLogin(
            coordinatorURL: coordinatorURL,
            onDisplayCode: onDisplayCode,
            onPollTick: onPollTick,
            openBrowser: openBrowser,
            onEvent: onEvent
        )
        onEvent?(.linked)
        return token
    } catch {
        let message = (error as? DeviceAuthError)?.description ?? error.localizedDescription
        onEvent?(.error(message: message))
        throw error
    }
}

/// The flow body behind `performDeviceCodeLogin`; the public wrapper owns the
/// terminal `.linked`/`.error` event emission.
private func runDeviceCodeLogin(
    coordinatorURL: String,
    onDisplayCode: @Sendable (String, String, Int) -> Void,
    onPollTick: (@Sendable () -> Void)?,
    openBrowser: Bool,
    onEvent: (@Sendable (DeviceLoginEvent) -> Void)?
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

    // Display the code to the user; notify the machine-readable seam.
    onDisplayCode(dc.user_code, dc.verification_uri, dc.expires_in)
    onEvent?(.code(userCode: dc.user_code, verificationURI: dc.verification_uri, expiresIn: dc.expires_in))

    // Try to open the browser automatically.
    if openBrowser {
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [dc.verification_uri]
        openProcess.standardOutput = FileHandle.nullDevice
        openProcess.standardError = FileHandle.nullDevice
        _ = try? openProcess.run()
    }

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
            // Persist the linked account id next to the token (best-effort)
            // for daemon-state identity. Authenticated earnings can recover
            // it later, so a local write failure must not fail the link.
            if let accountID = tokenResp.accountID, !accountID.isEmpty {
                try? ProviderAccountStore.save(accountID)
            }
            return token

        default:
            // expired or error
            let message = tokenResp.error?.message ?? "Device code expired or invalid"
            throw DeviceAuthError.authorizationFailed(message)
        }
    }

    throw DeviceAuthError.deviceCodeExpired
}
