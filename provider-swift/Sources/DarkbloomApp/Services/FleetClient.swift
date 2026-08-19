import Foundation

/// Errors surfaced by the coordinator fleet client.
enum FleetClientError: Error, Equatable, LocalizedError {
    /// The Privy access token was rejected with HTTP 401 (expired or
    /// revoked). The session must be re-established — retrying the same
    /// token cannot succeed. Note the coordinator answers 403 (not 401) for
    /// non-JWT credentials, so API keys never masquerade as expiry here.
    case sessionExpired
    /// The coordinator answered with a non-2xx status other than 401.
    case httpError(statusCode: Int, detail: String?)
    /// The configured coordinator base URL cannot form a request.
    case invalidBaseURL(String)
    /// No usable HTTP response at all — offline, DNS, timeout, or TLS.
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            "The Darkbloom session expired. Sign in again to continue."
        case .httpError(let statusCode, let detail):
            "The coordinator returned HTTP \(statusCode)."
                + (detail.map { " \($0)" } ?? "")
        case .invalidBaseURL(let rawValue):
            "The coordinator URL is not usable: \(rawValue)."
        case .unreachable(let reason):
            "The coordinator is not reachable. \(reason)"
        }
    }
}

/// Account-scoped coordinator reads (and the one write) backing My Macs.
///
/// These endpoints sit behind the coordinator's `requirePrivyAuth`
/// middleware, so every call carries a Privy access token as
/// `Authorization: Bearer …` — API keys are rejected server-side.
protocol FleetServicing: Sendable {
    /// `GET /v1/me/providers` — merged persisted + live fleet inventory.
    func providers(bearerToken: String) async throws -> MyMacsProvidersWireResponse

    /// `GET /v1/me/summary` — account earnings + fleet counts header.
    func summary(bearerToken: String) async throws -> MyMacsSummaryWireResponse

    /// `DELETE /v1/me/providers/{serial}` — remove a retained offline
    /// machine. Ownership and the online-machine guard (403/409) are
    /// enforced coordinator-side; this client only transports.
    func deleteProvider(removalToken: String, bearerToken: String) async throws
}

/// Foundation-URLSession fleet client.
///
/// Why Foundation instead of the CLI path: the `darkbloom` CLI has no
/// account-scoped calls (its `login` is the RFC 8628 device-code flow), and
/// My Macs renders the same account view the console shows. This client
/// stays inside the app target's no-ProviderCore constraint and decodes via
/// the existing `MyMacsWireDecoding` boundary, so no JSON or Go timestamp
/// conventions leak into the store.
///
/// Test seam: the transport is an injected closure. Production uses
/// `URLSession.shared`; tests inject a fake — no URLProtocol, no network.
struct FleetClient: FleetServicing {
    typealias DataTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Production coordinator (deploy/environments/prod.env `COORDINATOR_URL`).
    static let defaultCoordinatorBaseURL = URL(string: "https://api.darkbloom.dev")!

    /// Environment override for dev-coordinator smoke runs, e.g.
    /// `DARKBLOOM_COORDINATOR_URL=https://api.dev.darkbloom.xyz`.
    static let baseURLEnvironmentKey = "DARKBLOOM_COORDINATOR_URL"

    private let baseURL: URL
    private let decoder: any MyMacsWireDecoding
    private let transport: DataTransport

    init(
        baseURL: URL,
        decoder: any MyMacsWireDecoding = MyMacsWireDecoder(),
        transport: @escaping DataTransport
    ) {
        self.baseURL = baseURL
        self.decoder = decoder
        self.transport = transport
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        decoder: any MyMacsWireDecoding = MyMacsWireDecoder()
    ) {
        self.init(
            baseURL: Self.resolveBaseURL(environment: environment),
            decoder: decoder
        ) { request in
            try await URLSession.shared.data(for: request)
        }
    }

    static func resolveBaseURL(environment: [String: String]) -> URL {
        guard let rawValue = environment[baseURLEnvironmentKey],
              let url = URL(string: rawValue),
              url.scheme?.hasPrefix("http") == true
        else {
            return defaultCoordinatorBaseURL
        }
        return url
    }

    func providers(bearerToken: String) async throws -> MyMacsProvidersWireResponse {
        let data = try await send(Self.providersRequest(bearerToken: bearerToken, baseURL: baseURL))
        return try decoder.decodeProviders(from: data)
    }

    func summary(bearerToken: String) async throws -> MyMacsSummaryWireResponse {
        let data = try await send(Self.summaryRequest(bearerToken: bearerToken, baseURL: baseURL))
        return try decoder.decodeSummary(from: data)
    }

    func deleteProvider(removalToken: String, bearerToken: String) async throws {
        _ = try await send(
            Self.deleteRequest(removalToken: removalToken, bearerToken: bearerToken, baseURL: baseURL)
        )
    }

    // MARK: - Request construction (pure, pinned by tests)

    static func providersRequest(bearerToken: String, baseURL: URL) throws -> URLRequest {
        try authorizedRequest("GET", path: ["v1", "me", "providers"], bearerToken: bearerToken, baseURL: baseURL)
    }

    static func summaryRequest(bearerToken: String, baseURL: URL) throws -> URLRequest {
        try authorizedRequest("GET", path: ["v1", "me", "summary"], bearerToken: bearerToken, baseURL: baseURL)
    }

    static func deleteRequest(
        removalToken: String,
        bearerToken: String,
        baseURL: URL
    ) throws -> URLRequest {
        try authorizedRequest(
            "DELETE",
            path: ["v1", "me", "providers", removalToken],
            bearerToken: bearerToken,
            baseURL: baseURL
        )
    }

    private static func authorizedRequest(
        _ method: String,
        path: [String],
        bearerToken: String,
        baseURL: URL
    ) throws -> URLRequest {
        var url = baseURL
        for component in path {
            url.append(component: component)
        }
        guard url.scheme != nil else {
            throw FleetClientError.invalidBaseURL(baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Matches coordinator/api extractBearerToken; the token is a Privy
        // JWT obtained through the console app-link handoff.
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    // MARK: - Transport + status mapping

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw FleetClientError.unreachable(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FleetClientError.unreachable("The response was not HTTP.")
        }
        switch httpResponse.statusCode {
        case 200 ..< 300:
            return data
        case 401:
            throw FleetClientError.sessionExpired
        default:
            throw FleetClientError.httpError(
                statusCode: httpResponse.statusCode,
                detail: Self.errorDetail(from: data)
            )
        }
    }

    /// Coordinator error bodies are `{"error": {"type", "message", "code"}}`
    /// (`errorResponse` in coordinator/api/httputil.go); surface `message`.
    private static func errorDetail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObject = object["error"] as? [String: Any],
              let message = errorObject["message"] as? String,
              !message.isEmpty
        else {
            return nil
        }
        return message
    }
}
