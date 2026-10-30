import Foundation

/// A feature that Darkbloom opens to accounts from a waitlist: an account
/// joins the feature's waitlist, and Darkbloom approves it. The coordinator
/// keeps one waitlist per feature (`/v1/waitlists/{feature}`).
enum FeatureWaitlistFeature: String, CaseIterable, Sendable {
    /// Serving one model with two to four Macs (`darkbloom cluster`).
    case cluster
    /// Hosting Darkbloom Sandbox CI jobs (`darkbloom sandbox`).
    case sandbox

    /// The feature as the sentences of the CLI name it.
    var title: String {
        switch self {
        case .cluster: "clusters"
        case .sandbox: "Darkbloom Sandbox"
        }
    }

    /// The waitlist as the sentences of the CLI name it: "the cluster
    /// waitlist".
    var waitlistName: String {
        switch self {
        case .cluster: "cluster waitlist"
        case .sandbox: "Darkbloom Sandbox waitlist"
        }
    }
}

/// The account's place on a waitlist, as the coordinator answers it.
struct FeatureWaitlistPlace: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// The account has not joined, and no admin decided on it.
        case none
        case waitlisted
        case approved
        case revoked
    }

    let feature: String
    let status: Status
    /// The account's place in line while it is waitlisted.
    let position: Int?
    let requestedAt: Date?
    let decidedAt: Date?

    enum CodingKeys: String, CodingKey {
        case feature, status, position
        case requestedAt = "requested_at"
        case decidedAt = "decided_at"
    }
}

/// What an account tells the coordinator when it joins: the Mac it joins
/// from and how many Macs it plans to use.
struct FeatureWaitlistRequest: Codable, Equatable, Sendable {
    let chip: String
    let memoryGB: Int
    let macCount: Int

    enum CodingKeys: String, CodingKey {
        case chip
        case memoryGB = "memory_gb"
        case macCount = "mac_count"
    }
}

/// The answer to a waitlist call.
enum FeatureWaitlistLookup: Equatable, Sendable {
    /// The account's place.
    case place(FeatureWaitlistPlace)
    /// The coordinator has no waitlists: one released before them answers
    /// 404 for the route.
    case notOffered
    /// There is no login token, or the coordinator does not take it.
    case needsLogin
    /// The coordinator could not be asked, or answered something else.
    case unavailable(String)
}

/// Calls the waitlist routes of the coordinator with this Mac's login token.
struct FeatureWaitlistClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 10
    static let maximumAnswerBytes = 64 * 1024

    let base: URL
    /// The login token of `darkbloom login`; without one the call still
    /// tells a coordinator without waitlists (404) from one that wants a
    /// login (401).
    let token: String?
    var transport: Transport = FeatureWaitlistClient.live

    /// The waitlist base of a coordinator HTTP base: HTTPS, or plain HTTP
    /// only to this Mac's loopback, so the token never crosses the network
    /// in the clear.
    static func base(httpBase: String) -> URL? {
        guard let components = URLComponents(string: httpBase),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              components.query == nil, components.fragment == nil
        else { return nil }
        return components.url
    }

    /// The account's place on the feature's waitlist.
    func place(_ feature: FeatureWaitlistFeature) async -> FeatureWaitlistLookup {
        await call(feature, method: "GET", body: nil)
    }

    /// Joins the feature's waitlist. An account already on it keeps its
    /// place; an approved or revoked account is answered as it is.
    func join(_ feature: FeatureWaitlistFeature, _ request: FeatureWaitlistRequest) async -> FeatureWaitlistLookup {
        guard let body = try? JSONEncoder().encode(request) else { return .unavailable("could not encode the request") }
        return await call(feature, method: "POST", body: body)
    }

    private func call(_ feature: FeatureWaitlistFeature, method: String, body: Data?) async -> FeatureWaitlistLookup {
        var request = URLRequest(url: base.appendingPathComponent("v1/waitlists/\(feature.rawValue)"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .unavailable(error.localizedDescription)
        }
        return Self.answer(status: response.statusCode, body: data)
    }

    /// The lookup for one answer of the coordinator.
    static func answer(status: Int, body: Data) -> FeatureWaitlistLookup {
        switch status {
        case 200:
            guard let place = try? decoder.decode(FeatureWaitlistPlace.self, from: body) else {
                return .unavailable("the coordinator's answer could not be read")
            }
            return .place(place)
        case 404:
            return .notOffered
        case 401:
            return .needsLogin
        default:
            let message = refusal(body)?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return .unavailable("HTTP \(status): \(message)")
        }
    }

    /// The coordinator's error envelope, `{"error": {"message": ...}}`.
    private struct Refusal: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail
    }

    private static func refusal(_ body: Data) -> Refusal.Detail? {
        (try? JSONDecoder().decode(Refusal.self, from: body))?.error
    }

    /// Reads the coordinator's RFC 3339 times, with or without fractional
    /// seconds.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 time: \(text)"))
        }
        return decoder
    }

    /// The shared session, which follows no redirect, so the token goes to
    /// the configured coordinator only. It reads at most one byte past
    /// `maximumAnswerBytes`.
    static let live: Transport = { request in
        let (bytes, received) = try await URLSession.shared.bytes(for: request, delegate: NoRedirects())
        guard let response = received as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= Int64(maximumAnswerBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumAnswerBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (data, response)
    }
}

/// Refuses every redirect of a waitlist call.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
