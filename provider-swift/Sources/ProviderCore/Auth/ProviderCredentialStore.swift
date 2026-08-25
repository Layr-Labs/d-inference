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

        do {
            try ProviderAccountStore.save(accountID)
            try ProviderIssuerStore.save(issuer)
            // Token publication is deliberately last.
            try AuthTokenStore.save(token)
        } catch {
            // A failed login must not leave metadata that looks linked. The
            // token write is atomic, so it is either absent or complete here.
            try? AuthTokenStore.delete()
            try? ProviderAccountStore.delete()
            try? ProviderIssuerStore.delete()
            throw error
        }
    }
}

public enum ProviderCredentialStoreError: LocalizedError, Sendable, Equatable {
    case missingToken
    case missingAccountID
    case invalidCoordinatorURL

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "provider token is missing"
        case .missingAccountID:
            "coordinator authorized the device without an account identity"
        case .invalidCoordinatorURL:
            "coordinator URL is invalid"
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
