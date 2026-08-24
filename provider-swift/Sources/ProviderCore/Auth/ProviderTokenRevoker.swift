import Foundation

public struct ProviderTokenRevoker: Sendable {
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(urlSession: URLSession = .shared) {
        send = { try await urlSession.data(for: $0) }
    }

    init(
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.send = send
    }

    public func revoke(
        coordinatorURL: String,
        token: String
    ) async throws {
        guard !token.isEmpty else {
            throw ProviderTokenRevokeError.missingToken
        }
        let base = coordinatorHTTPBase(coordinatorURL)
        guard let url = URL(string: base + "/v1/device/token") else {
            throw ProviderTokenRevokeError.invalidCoordinatorURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderTokenRevokeError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ProviderTokenRevokeError.rejected(status: http.statusCode)
        }
    }
}

public enum ProviderTokenRevokeError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidCoordinatorURL
    case invalidResponse
    case rejected(status: Int)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "provider token is missing"
        case .invalidCoordinatorURL:
            return "coordinator URL is invalid"
        case .invalidResponse:
            return "coordinator returned an invalid response"
        case .rejected(let status):
            return "coordinator rejected provider unlink (HTTP \(status))"
        }
    }
}
