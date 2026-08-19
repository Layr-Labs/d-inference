import Foundation
import ProviderCoreFoundation

/// Errors surfaced by the local-endpoint HTTP client. Transport-level
/// failures (connection refused, timeout, DNS) are normalized to
/// `.unreachable` so UI copy can distinguish "server answered with an
/// error" from "nothing is listening".
enum LocalEndpointError: Error, Equatable, LocalizedError {
    /// The discovery record produced a URL we cannot form a request against.
    case invalidEndpoint
    /// The server answered with a non-2xx status.
    case httpError(statusCode: Int, detail: String?)
    /// No HTTP response at all — nothing is listening (or it hung).
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The local endpoint URL from the discovery record is not usable."
        case .httpError(let statusCode, let detail):
            "The local endpoint returned HTTP \(statusCode)."
                + (detail.map { " \($0)" } ?? "")
        case .unreachable(let reason):
            "The local endpoint is not reachable. \(reason)"
        }
    }
}

/// Presentation-grade async client for the provider's local
/// OpenAI-compatible server (the one that writes `~/.darkbloom/local.json`).
///
/// Foundation-only, deliberately minimal: chat completions (non-streaming
/// shape *in*, SSE streaming out) and a tolerant `/models` listing. This is
/// a wrapper over what the CLI/daemon already serves — no inference logic
/// lives here, and nothing in the app target gains an MLX/ProviderCore
/// dependency.
///
/// Test seam: both transports are injected closures. Production code uses
/// `init(baseURL:apiKey:timeout:)` backed by `URLSession`; tests inject
/// `dataTransport` / `lineTransport` fakes — no URLProtocol, no network.
struct LocalEndpointClient: Sendable {
    /// OpenAI chat message wire shape (internal — not a library API).
    struct ChatMessage: Codable, Equatable, Sendable {
        var role: String
        var content: String
    }

    /// One parsed SSE chunk worth surfacing to the UI.
    struct ChatDelta: Equatable, Sendable {
        var content: String
        var finishReason: String?

        init(content: String, finishReason: String? = nil) {
            self.content = content
            self.finishReason = finishReason
        }
    }

    /// Non-streaming request/response transport (used by `listModels`).
    typealias DataTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Streaming transport: returns the response plus an SSE line sequence.
    /// Production wraps `URLSession.bytes(for:).lines`; tests yield canned
    /// lines. Lines are raw HTTP body lines — the client does SSE framing
    /// (`data:` prefix, `[DONE]`, comment/blank tolerance) itself.
    typealias LineTransport = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)

    let baseURL: URL
    let apiKey: String?

    private let dataTransport: DataTransport
    private let lineTransport: LineTransport

    /// Production initializer. `timeout` builds a dedicated session with a
    /// tighter `timeoutIntervalForRequest` (used for health probes); leave
    /// nil for chat so cold model loads aren't cut off by a probe-sized
    /// timeout.
    init(baseURL: URL, apiKey: String?, timeout: TimeInterval? = nil, session: URLSession = .shared) {
        let session: URLSession = {
            guard let timeout else { return session }
            let configuration = session.configuration
            configuration.timeoutIntervalForRequest = timeout
            return URLSession(configuration: configuration)
        }()
        self.init(
            baseURL: baseURL,
            apiKey: apiKey,
            dataTransport: { try await session.data(for: $0) },
            lineTransport: { request in
                let (bytes, response) = try await session.bytes(for: request)
                let lines = AsyncThrowingStream<String, Error> { continuation in
                    let pump = Task {
                        do {
                            for try await line in bytes.lines {
                                continuation.yield(line)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in pump.cancel() }
                }
                return (lines, response)
            }
        )
    }

    /// Convenience for building a client straight from a discovery record.
    init(info: LocalEndpointInfo, timeout: TimeInterval? = nil) {
        let url = URL(string: info.baseURL) ?? URL(string: "http://127.0.0.1:\(info.port)/v1")!
        self.init(baseURL: url, apiKey: info.apiKey, timeout: timeout)
    }

    /// Test seam: fully injected transports.
    init(
        baseURL: URL,
        apiKey: String?,
        dataTransport: @escaping DataTransport,
        lineTransport: @escaping LineTransport
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.dataTransport = dataTransport
        self.lineTransport = lineTransport
    }

    // MARK: - Chat completions (SSE streaming)

    /// Stream one chat completion. Yields one `ChatDelta` per SSE data chunk
    /// that carries content or a finish reason; role-only chunks, comments,
    /// blank lines, and malformed `data:` payloads are skipped (tolerant by
    /// design — a broken chunk must not kill an otherwise-good stream).
    func streamChat(model: String, messages: [ChatMessage]) -> AsyncThrowingStream<ChatDelta, Error> {
        let request: URLRequest
        do {
            request = try makeChatRequest(model: model, messages: messages)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let lineTransport = self.lineTransport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (lines, response) = try await lineTransport(request)
                    let status = Self.httpStatus(of: response)
                    guard (200..<300).contains(status) else {
                        throw LocalEndpointError.httpError(statusCode: status, detail: nil)
                    }
                    for try await line in lines {
                        switch Self.parseSSELine(line) {
                        case .delta(let delta):
                            continuation.yield(delta)
                        case .done:
                            continuation.finish()
                            return
                        case .ignored:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Model catalog

    /// GET `{base}/models`. Defensive about shape variance: a 2xx body we
    /// cannot interpret decodes to `[]` rather than failing (the probe the
    /// stores run against this only needs liveness + a best-effort catalog).
    /// Non-2xx statuses surface as typed `.httpError` — the caller maps
    /// 404 to "catalog unavailable" and transport failures to "unreachable".
    func listModels() async throws -> [String] {
        let request = makeJSONRequest(path: "models", method: "GET")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataTransport(request)
        } catch {
            throw Self.normalize(error)
        }
        let status = Self.httpStatus(of: response)
        guard (200..<300).contains(status) else {
            throw LocalEndpointError.httpError(statusCode: status, detail: nil)
        }
        guard let decoded = try? JSONDecoder().decode(ModelListResponse.self, from: data) else {
            return []
        }
        return decoded.data?.compactMap(\.id) ?? []
    }

    // MARK: - SSE parsing (pure, testable)

    enum SSEParseResult: Equatable {
        case delta(ChatDelta)
        case done
        case ignored
    }

    /// Parse one raw SSE line. Anything that is not a `data:` payload
    /// (blank lines, `:` comments, `event:` fields) and any malformed or
    /// content-less chunk is ignored — tolerance over strictness for a
    /// UI-only consumer.
    static func parseSSELine(_ rawLine: String) -> SSEParseResult {
        let trimmed = rawLine.trimmingCharacters(in: .newlines)
        guard trimmed.hasPrefix("data:") else { return .ignored }
        let payload = trimmed.dropFirst("data:".count).drop(while: { $0 == " " })
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChatCompletionsChunk.self, from: data),
              let choice = chunk.choices?.first
        else {
            return .ignored
        }
        let content = choice.delta?.content ?? ""
        let finishReason = choice.finishReason
        guard !content.isEmpty || finishReason != nil else { return .ignored }
        return .delta(ChatDelta(content: content, finishReason: finishReason))
    }

    // MARK: - Error normalization

    static func normalize(_ error: Error) -> LocalEndpointError {
        if let endpointError = error as? LocalEndpointError { return endpointError }
        if let urlError = error as? URLError {
            return .unreachable(urlError.localizedDescription)
        }
        return .unreachable(error.localizedDescription)
    }

    // MARK: - Requests

    private static func httpStatus(of response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func makeChatRequest(model: String, messages: [ChatMessage]) throws -> URLRequest {
        var request = makeJSONRequest(path: "chat/completions", method: "POST")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONEncoder().encode(
                ChatCompletionsRequest(model: model, messages: messages, stream: true)
            )
        } catch {
            throw LocalEndpointError.invalidEndpoint
        }
        return request
    }

    private func makeJSONRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An empty key means the local server runs without auth.
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Wire shapes (internal; OpenAI protocol)

    private struct ChatCompletionsRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    struct ChatCompletionsChunk: Decodable {
        let choices: [Choice]?

        struct Choice: Decodable {
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        struct Delta: Decodable {
            let role: String?
            let content: String?
        }
    }

    struct ModelListResponse: Decodable {
        let data: [Entry]?

        struct Entry: Decodable {
            let id: String?
        }
    }
}
