import Foundation

/// The canonical coordinator that issued a provider's long-lived device token.
///
/// This value is part of the credential binding: configuration may change after
/// login, but revocation must always go back to the issuer that minted the token.
public enum ProviderIssuerStore: Sendable {
    public static func issuerPath() -> URL {
        if let override = ProcessInfo.processInfo.environment[
            "DARKBLOOM_PROVIDER_ISSUER_PATH"
        ], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom")
            .appendingPathComponent("provider_issuer")
    }

    public static func load() -> String? {
        guard let content = try? String(
            contentsOf: issuerPath(),
            encoding: .utf8
        ) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func save(_ issuerURL: String) throws {
        let path = issuerPath()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try issuerURL.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }

    public static func delete() throws {
        let path = issuerPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

/// Persists the three pieces of one provider credential as a publication
/// transaction. Account and issuer metadata are written first; the bearer token
/// is written last and remains the sole "logged in" marker. Consequently any
/// reader that can observe the new token can also observe its account and issuer.
public struct ProviderCredential: Sendable, Equatable {
    public let token: String
    public let accountID: String
    public let issuer: String

    public init(token: String, accountID: String, issuer: String) {
        self.token = token
        self.accountID = accountID
        self.issuer = issuer
    }
}

public enum ProviderCredentialStore: Sendable {
    public static func save(
        token: String,
        accountID: String,
        coordinatorURL: String
    ) throws {
        guard !token.isEmpty else {
            throw ProviderCredentialStoreError.missingToken
        }
        guard !accountID.isEmpty else {
            throw ProviderCredentialStoreError.missingAccountID
        }
        let issuer = try canonicalCoordinatorIssuer(coordinatorURL)

        try ProviderCredentialProcessLock.withLock {
            guard AuthTokenStore.load() == nil else {
                throw ProviderCredentialStoreError.alreadyLoggedIn
            }

            do {
                try ProviderAccountStore.save(accountID)
                try ProviderIssuerStore.save(issuer)
                // Token publication is deliberately last. Readers take the
                // same kernel lock, so they observe all three files or none.
                try AuthTokenStore.save(token)
            } catch {
                try? AuthTokenStore.delete()
                try? ProviderAccountStore.delete()
                try? ProviderIssuerStore.delete()
                throw error
            }
        }
    }

    /// Loads one coherent credential snapshot. A token without both binding
    /// records is rejected instead of being sent to an unverified endpoint.
    public static func load() throws -> ProviderCredential? {
        try ProviderCredentialProcessLock.withLock {
            try loadUnlocked()
        }
    }

    /// Returns the credential only when its recorded issuer matches the
    /// configured coordinator origin.
    public static func load(
        for coordinatorURL: String
    ) throws -> ProviderCredential? {
        let expectedIssuer = try canonicalCoordinatorIssuer(coordinatorURL)
        return try ProviderCredentialProcessLock.withLock {
            guard let credential = try loadUnlocked() else {
                return nil
            }
            guard credential.issuer == expectedIssuer else {
                throw ProviderCredentialStoreError.issuerMismatch(
                    expected: expectedIssuer,
                    actual: credential.issuer
                )
            }
            return credential
        }
    }

    public static func authenticationToken(
        for coordinatorURL: String
    ) throws -> String? {
        try load(for: coordinatorURL)?.token
    }

    /// Deletes the snapshot loaded by the caller. Comparing under the kernel
    /// lock prevents a delayed logout from deleting a newer login.
    public static func delete(
        matching expected: ProviderCredential?
    ) throws {
        try ProviderCredentialProcessLock.withLock {
            let current = try loadUnlocked()
            guard current == expected else {
                throw ProviderCredentialStoreError.credentialChanged
            }

            // Token removal unpublishes the credential before metadata cleanup.
            try AuthTokenStore.delete()
            try ProviderAccountStore.delete()
            try ProviderIssuerStore.delete()
        }
    }

    /// Explicit recovery for credentials created before issuer binding existed.
    /// No remote revocation is attempted because the issuing origin is unknown.
    public static func deleteLocalCredential() throws {
        try ProviderCredentialProcessLock.withLock {
            try AuthTokenStore.delete()
            try ProviderAccountStore.delete()
            try ProviderIssuerStore.delete()
        }
    }

    private static func loadUnlocked() throws -> ProviderCredential? {
        guard let token = AuthTokenStore.load() else {
            return nil
        }
        guard let accountID = ProviderAccountStore.load(),
              let issuer = ProviderIssuerStore.load()
        else {
            throw ProviderCredentialStoreError.incompleteCredential
        }
        return ProviderCredential(
            token: token,
            accountID: accountID,
            issuer: issuer
        )
    }
}

public enum ProviderCredentialStoreError: LocalizedError, Sendable, Equatable {
    case missingToken
    case missingAccountID
    case invalidCoordinatorURL
    case alreadyLoggedIn
    case incompleteCredential
    case issuerMismatch(expected: String, actual: String)
    case credentialChanged
    case lockUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "provider token is missing"
        case .missingAccountID:
            "coordinator authorized the device without an account identity"
        case .invalidCoordinatorURL:
            "coordinator URL is invalid"
        case .alreadyLoggedIn:
            "this Mac is already linked to a provider account"
        case .incompleteCredential:
            "the saved provider credential has no verifiable account or issuer; run `darkbloom logout --local-only`, then sign in again"
        case .issuerMismatch(let expected, let actual):
            "the saved provider credential belongs to \(actual), not \(expected); switch back or sign out before changing coordinators"
        case .credentialChanged:
            "the saved provider credential changed during account unlink; retry without deleting the newer login"
        case .lockUnavailable(let reason):
            "could not lock the saved provider credential: \(reason)"
        }
    }
}

/// Normalize an HTTP(S) or WebSocket coordinator URL to the issuing HTTP
/// origin. Paths, query parameters, fragments, and trailing slashes are not
/// credential identity and are intentionally discarded.
public func canonicalCoordinatorIssuer(_ rawURL: String) throws -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
          let rawScheme = components.scheme?.lowercased(),
          let host = components.host,
          !host.isEmpty,
          components.user == nil,
          components.password == nil
    else {
        throw ProviderCredentialStoreError.invalidCoordinatorURL
    }

    switch rawScheme {
    case "https", "wss":
        components.scheme = "https"
    case "http", "ws":
        components.scheme = "http"
    default:
        throw ProviderCredentialStoreError.invalidCoordinatorURL
    }
    components.host = host.lowercased()
    components.path = ""
    components.query = nil
    components.fragment = nil

    guard let issuer = components.url?.absoluteString,
          !issuer.isEmpty
    else {
        throw ProviderCredentialStoreError.invalidCoordinatorURL
    }
    return issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
