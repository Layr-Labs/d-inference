import Foundation

/// Logout must destroy the running process's credential/key custody before it
/// can remove the saved credential, even if that file has already disappeared.
public enum ProviderLogout {
    public enum Outcome: Sendable, Equatable {
        case revoked
        case remoteUnconfirmed
        case noCredential
    }

    public static func perform(
        stopProvider: () async throws -> Void,
        loadToken: () -> String? = AuthTokenStore.load,
        revokeToken: (String) async -> Bool,
        deleteToken: () throws -> Void = AuthTokenStore.delete
    ) async throws -> Outcome {
        try await stopProvider()
        let outcome: Outcome
        if let token = loadToken() {
            outcome = await revokeToken(token) ? .revoked : .remoteUnconfirmed
        } else {
            outcome = .noCredential
        }
        try deleteToken()
        return outcome
    }

    /// Revoke only this saved provider token. Never follow a redirect with it or
    /// interpret an old server's generic success page as revocation confirmation.
    public static func revokeToken(
        _ token: String,
        coordinatorURL: String,
        session: URLSession? = nil
    ) async -> Bool {
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n"),
              var components = URLComponents(string: coordinatorURL),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else {
            return false
        }
        switch components.scheme?.lowercased() {
        case "ws", "http": components.scheme = "http"
        case "wss", "https": components.scheme = "https"
        default: return false
        }
        components.path = "/v1/device/revoke"
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { return false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let client = session ?? URLSession(configuration: configuration)
        defer { if session == nil { client.invalidateAndCancel() } }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await client.data(for: request, delegate: NoLogoutRedirect())
            return (response as? HTTPURLResponse)?.statusCode == 204
        } catch {
            // Transport errors (including offline/cancellation) do not prevent
            // local logout after the process is stopped. Never log token/body.
            return false
        }
    }
}

private final class NoLogoutRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
