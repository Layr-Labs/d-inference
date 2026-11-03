import Foundation

/// A waitlist of the coordinator's catalog and the account's place on it, as
/// `GET /v1/waitlists/{feature}` answers it. Darkbloom opens a feature to the
/// accounts it approves from the feature's waitlist, and the coordinator's
/// catalog is the only list of waitlists: the CLI knows none by itself.
struct FeatureWaitlistPlace: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// The account has not joined, and no admin decided on it.
        case none
        case waitlisted
        case approved
        case revoked
    }

    /// How many Macs a join may name.
    struct MacCount: Codable, Equatable, Sendable {
        let min: Int
        let max: Int
    }

    /// The waitlist's id in the coordinator's URLs, such as `cluster`.
    let feature: String
    /// The waitlist as sentences name it, such as `Clusters`.
    let title: String
    let summary: String?
    /// What an approved account runs, such as `darkbloom cluster`; absent
    /// when the waitlist has none.
    let startCommand: String?
    /// Absent when the waitlist asks for no Mac: a join then names none.
    let macCount: MacCount?
    let status: Status
    /// The account's place in line while it is waitlisted.
    let position: Int?
    let requestedAt: Date?
    let decidedAt: Date?

    enum CodingKeys: String, CodingKey {
        case feature, title, summary, status, position
        case startCommand = "start_command"
        case macCount = "mac_count"
        case requestedAt = "requested_at"
        case decidedAt = "decided_at"
    }

    /// The Mac count a join of this waitlist names: `macs`, by default the
    /// fewest the waitlist takes, or nil for a waitlist that asks for no Mac.
    func joinMacCount(_ macs: Int?) throws -> Int? {
        guard let range = macCount else {
            guard macs == nil else {
                throw FeatureWaitlistMacsRefusal("--macs does not apply to the \(title) waitlist: it asks for no Mac.")
            }
            return nil
        }
        let count = macs ?? range.min
        // Compared, not made a ClosedRange: a range the coordinator got wrong
        // must not trap.
        guard count >= range.min, count <= range.max else {
            throw FeatureWaitlistMacsRefusal(range.min == range.max
                ? "--macs must be \(range.min) for the \(title) waitlist."
                : "--macs must be between \(range.min) and \(range.max) for the \(title) waitlist.")
        }
        return count
    }
}

/// `--macs` outside what a waitlist takes.
struct FeatureWaitlistMacsRefusal: Error, Equatable, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

/// Every waitlist of the coordinator's catalog, in its order, with the
/// account's place on each: `GET /v1/waitlists`.
struct FeatureWaitlists: Codable, Equatable, Sendable {
    let data: [FeatureWaitlistPlace]

    /// The waitlist `name` names: its id ignoring case, or that id with a
    /// plural `s` or `es` (`clusters`, `sandboxes`). An exact id wins, and a
    /// plural that two ids share (`boxes` of `box` and `boxe`) names neither.
    func named(_ name: String) -> FeatureWaitlistPlace? {
        let name = name.lowercased()
        if let exact = data.first(where: { $0.feature.lowercased() == name }) { return exact }
        let plurals = data.filter { [$0.feature.lowercased() + "s", $0.feature.lowercased() + "es"].contains(name) }
        return plurals.count == 1 ? plurals[0] : nil
    }
}

/// What an account tells the coordinator when it joins. A waitlist that asks
/// for Macs gets the Mac the account joins from and how many Macs it plans to
/// use; another gets nothing (`{}`).
struct FeatureWaitlistRequest: Codable, Equatable, Sendable {
    var chip: String? = nil
    var memoryGB: Int? = nil
    var macCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case chip
        case memoryGB = "memory_gb"
        case macCount = "mac_count"
    }
}

/// Why a waitlist call has no answer to show.
enum FeatureWaitlistProblem: Error, Equatable, Sendable {
    /// The coordinator answered 404: it has no such waitlist. One released
    /// before waitlists answers 404 for every waitlist route.
    case notOffered
    /// The coordinator answered 401: there is no login token, or it does not
    /// take this one.
    case needsLogin
    /// The coordinator could not be asked, or answered something else.
    case unavailable(String)
}

/// The answer to a call about one waitlist.
typealias FeatureWaitlistLookup = Result<FeatureWaitlistPlace, FeatureWaitlistProblem>

/// Calls the waitlist routes of the coordinator with this Mac's login token.
struct FeatureWaitlistClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The deadline of a whole call; it is also the request's idle timeout.
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
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(host)),
              components.query == nil, components.fragment == nil
        else { return nil }
        return components.url
    }

    /// Every waitlist of the catalog with the account's place on it.
    func waitlists() async -> Result<FeatureWaitlists, FeatureWaitlistProblem> {
        await call("v1/waitlists", method: "GET", body: nil)
    }

    /// The account's place on the waitlist `feature`.
    func place(_ feature: String) async -> FeatureWaitlistLookup {
        await call("v1/waitlists/\(feature)", method: "GET", body: nil)
    }

    /// Joins the waitlist `feature`. An account already on it keeps its
    /// place; an approved or revoked account is answered as it is.
    func join(_ feature: String, _ request: FeatureWaitlistRequest) async -> FeatureWaitlistLookup {
        guard let body = try? JSONEncoder().encode(request) else { return .failure(.unavailable("could not encode the request")) }
        return await call("v1/waitlists/\(feature)", method: "POST", body: body)
    }

    private func call<Answer: Decodable>(_ path: String, method: String, body: Data?) async -> Result<Answer, FeatureWaitlistProblem> {
        var request = URLRequest(url: base.appendingPathComponent(path),
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
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.unavailable("no answer within \(Int(Self.timeout)) seconds"))
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
        return Self.answer(status: response.statusCode, body: data)
    }

    /// The answer, or the problem, of one response of the coordinator.
    static func answer<Answer: Decodable>(status: Int, body: Data, as _: Answer.Type = Answer.self)
        -> Result<Answer, FeatureWaitlistProblem>
    {
        switch status {
        case 200:
            guard let answer = try? decoder.decode(Answer.self, from: body) else {
                return .failure(.unavailable("the coordinator's answer could not be read"))
            }
            return .success(answer)
        case 404:
            return .failure(.notOffered)
        case 401:
            return .failure(.needsLogin)
        default:
            let message = refusal(body)?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return .failure(.unavailable("HTTP \(status): \(message)"))
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
    private static var decoder: JSONDecoder {
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
    /// the configured coordinator only. The whole call ends after `timeout`:
    /// a request's own timeout only bounds the time between two reads.
    static let live: Transport = { request in
        try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await read(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let answer = try await group.next() else { throw URLError(.timedOut) }
            return answer
        }
    }

    /// Reads at most one byte past `maximumAnswerBytes`.
    private static func read(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
