import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import NIOFoundationCompat

/// The local router in the local API's responder stack, between the local key check and CORS (so a request with a
/// bad local key never reaches it, and this Mac's errors arrive as statuses). Without a router it is a pass-through.
public struct LocalRouterResponder<Inner: HTTPResponder>: HTTPResponder where Inner.Context == BasicRequestContext {
    public typealias Context = BasicRequestContext

    public let inner: Inner
    let router: LocalRouter?

    init(inner: Inner, router: LocalRouter?) {
        self.inner = inner
        self.router = router
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard let router else { return try await inner.respond(to: request, context: context) }
        let path = request.uri.path
        if request.method == .get, LocalRouterPolicy.isModelsPath(path) {
            return try await router.models(request, context: context, inner: inner)
        }
        guard request.method == .post, let upstreamPath = LocalRouterPolicy.upstreamPath(forLocalPath: path) else {
            return try await inner.respond(to: request, context: context)
        }
        return try await router.route(request, upstreamPath: upstreamPath, context: context, inner: inner)
    }
}

/// The router's state and its paths: this Mac (in process, the engine's response returned as it is), passing a
/// request on (`LocalRouterPolicy`), and the merged `/v1/models`.
public final class LocalRouter: Sendable {
    public struct Timing: Sendable {
        /// To put a passed-on request on the wire.
        public var connect: Duration = .seconds(10)
        /// The longest wait for a byte of a passed-on request's answer: `self` may queue for 120 s before its head.
        public var idle: Duration = .seconds(300)
        /// The whole of a model-list read: `/v1/models` never waits long on an unreachable coordinator, and answers
        /// within the 5 s an integration gives it.
        public var list: Duration = .seconds(3)
        public var listTTL: Duration = .seconds(30)
        public var catalogTTL: Duration = .seconds(300)
        /// How long a failed read is remembered, so an unreachable coordinator costs one try per period.
        public var failureTTL: Duration = .seconds(10)
        public init() {}
    }

    public let config: LocalRouterConfig
    let localModels: @Sendable () async -> [String]
    let localLimits: @Sendable (String) async -> LocalModelLimits?
    private let state = LocalRouterState()

    var makeTransport: @Sendable () -> any LocalRouterTransport { config.makeTransport }
    var log: @Sendable (String) -> Void { config.log }
    var timing: Timing { config.timing }

    /// - Parameters:
    ///   - localModels: this Mac's model ids, as its `/v1/models` lists them.
    ///   - localLimits: this Mac's engine limits for a model, when it knows them.
    public init(config: LocalRouterConfig,
                localModels: @escaping @Sendable () async -> [String],
                localLimits: @escaping @Sendable (String) async -> LocalModelLimits? = { _ in nil }) {
        self.config = config
        self.localModels = localModels
        self.localLimits = localLimits
    }

    public static let standardErrorLog: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data(("local router: " + line + "\n").utf8))
    }

    // MARK: - Inference

    /// This Mac first: its engine's answer, streamed or not, is returned as it is with one header added, unless this
    /// Mac can't take the request (`LocalRouterPolicy.passesOn`) and the route dials out.
    func route<Inner: HTTPResponder>(_ request: Request, upstreamPath: String, context: Inner.Context,
                                     inner: Inner) async throws -> Response {
        var request = request
        // Collected once, kept for a pass-on, within the engine's own ceilings (32 MiB for chat, 2 MiB otherwise).
        // The engine collects the body anyway: it is handed this same buffer, with no copy, and nothing on this Mac's
        // path parses it.
        let limit = upstreamPath == "/v1/chat/completions" ? localInferenceMaxUploadBytes : 2 * 1024 * 1024
        let body: ByteBuffer
        do {
            body = try await request.collectBody(upTo: limit)
        } catch is NIOTooManyBytesError {
            var response = Self.errorResponse(.contentTooLarge,
                message: "request body exceeds the \(limit / (1024 * 1024)) MiB local endpoint limit")
            response.headers[LocalRouterPolicy.servedByHeader] = LocalRouterPolicy.thisMac
            return response
        }
        var local = try await inner.respond(to: request, context: context)
        local.headers[LocalRouterPolicy.servedByHeader] = LocalRouterPolicy.thisMac
        guard LocalRouterPolicy.passesOn(localStatus: local.status) else { return local }
        // Only a request this Mac can't take reads the account key; without one, this Mac's answer stands.
        let (route, key) = config.effectiveRoute()
        guard let key else { return local }
        if local.status == .notFound,
           let answer = try await answerAliasHere(request, body: body, context: context, inner: inner) {
            local = answer
            guard LocalRouterPolicy.passesOn(localStatus: local.status) else { return local }
        }
        return try await passOn(body: body, clientHeaders: request.headers, upstreamPath: upstreamPath,
                                route: route, key: key, local: local)
    }

    /// A request that names a public alias of a build this Mac serves is this Mac's: its engine knows builds by their
    /// own ids only, so it is asked once more under the build's id, before any byte. (The coordinator's `self` list
    /// names the owner's builds by their aliases, and would otherwise send it back here.) Read only after this Mac's
    /// 404, with a route that dials out: the catalog is a coordinator read.
    private func answerAliasHere<Inner: HTTPResponder>(_ request: Request, body: ByteBuffer, context: Inner.Context,
                                                      inner: Inner) async throws -> Response? {
        guard let model = Self.model(in: body), let catalog = await catalog() else { return nil }
        let local = Set(await localModels())
        guard !local.contains(model), let build = catalog.aliasBuilds[model]?.first(where: local.contains),
              let renamed = Self.replacingModel(in: body, with: build) else { return nil }
        log("this Mac serves the requested alias as one of its own builds; answering here")
        var retry = request
        retry.body = RequestBody(buffer: renamed)
        var answer = try await inner.respond(to: retry, context: context)
        answer.headers[LocalRouterPolicy.servedByHeader] = LocalRouterPolicy.thisMac
        return answer
    }

    private func passOn(body: ByteBuffer, clientHeaders: HTTPFields, upstreamPath: String,
                        route: LocalSettings.Route, key: String, local: Response) async throws -> Response {
        let model = Self.model(in: body)
        func send(_ hop: LocalRouterUpstreamRoute) async throws -> Hop {
            try await self.send(hop, path: upstreamPath, body: body, clientHeaders: clientHeaders, key: key)
        }
        switch route {
        case .thisMac:
            return local  // Not reached: `effectiveRoute` gives a key only to a route that dials out.
        case .myMacs:
            // A `self` hop that could only come back to this Mac is not sent: the coordinator can't leave one Mac
            // out of a `self` request, and would queue it here, where it can't be taken now, for 120 s.
            if let model, await selfHopWouldReturnHere(model: model, key: key) {
                log("this Mac can't take the request and is the only one of your Macs serving its model; not passed on")
                return thisMacOnly(local, model: model)
            }
            log("this Mac answered \(local.status.code); passing the request on (self)")
            switch try await send(.mine) {
            case .answer(let response): return response
            case .refusal(let upstream, let bytes): return relayError(upstream, body: bytes, hop: .mine, key: key)
            }
        case .myMacsFirst:
            // `prefer`: the coordinator takes the owner's Macs first, then the network, among the Macs that can take
            // the request now, with no 120 s queue for a busy Mac of the owner's.
            log("this Mac answered \(local.status.code); passing the request on (prefer)")
            let network: (upstream: LocalRouterUpstreamResponse, bytes: ByteBuffer?)
            switch try await send(.prefer) {
            case .answer(let response): return response
            case .refusal(let upstream, let bytes):
                guard LocalRouterPolicy.asksYourMacs(afterNetworkStatus: upstream.status) else {
                    return relayError(upstream, body: bytes, hop: .prefer, key: key)
                }
                network = (upstream, bytes)
            }
            // No balance for the network: the owner's Macs, free, once.
            if let model, await selfHopWouldReturnHere(model: model, key: key) {
                log("no balance for the network, and this Mac is the only one of your Macs serving its model")
                return relayError(network.upstream, body: network.bytes, hop: .prefer, key: key)
            }
            log("no balance for the network; asking your Macs (self)")
            switch try await send(.mine) {
            case .answer(let response): return response
            case .refusal(let upstream, let bytes):
                guard LocalRouterPolicy.yourMacsCouldNotTakeIt(status: upstream.status) else {
                    return relayError(upstream, body: bytes, hop: .mine, key: key)
                }
                return relayError(network.upstream, body: network.bytes, hop: .prefer, key: key)
            }
        }
    }

    /// One upstream hop's outcome: an answer to relay as it is (a 2xx stream, or this Mac's 502 when the coordinator
    /// can't be reached), or the coordinator's refusal with its body read.
    private enum Hop {
        case answer(Response)
        case refusal(LocalRouterUpstreamResponse, ByteBuffer?)
    }

    private func send(_ hop: LocalRouterUpstreamRoute, path: String, body: ByteBuffer, clientHeaders: HTTPFields,
                      key: String) async throws -> Hop {
        let transport = await state.transport(makeTransport)
        let upstream: LocalRouterUpstreamResponse
        do {
            upstream = try await transport.send(upstreamRequest(
                hop: hop, path: path, body: body, clientHeaders: clientHeaders, key: key))
        } catch let error where error is CancellationError || Task.isCancelled {
            throw CancellationError()
        } catch {
            log("Darkbloom could not be reached: \(Self.plain(error))")
            var response = Self.errorResponse(.badGateway, message: "This Mac can't take this request, and Darkbloom "
                + "could not be reached to pass it on: \(Self.plain(error)).", code: "darkbloom_unreachable")
            response.headers[LocalRouterPolicy.routeUsedHeader] = hop.rawValue
            return .answer(response)
        }
        if (200..<300).contains(upstream.status) { return .answer(relay(upstream, hop: hop)) }
        return .refusal(upstream, await Self.collect(upstream.body, limit: 1024 * 1024))
    }

    /// The request's `model`, for the checks before a `self` hop; nil when the body isn't a JSON object naming one.
    /// Read only from a request this Mac can't take.
    private static func model(in body: ByteBuffer) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(buffer: body), options: [])) as? [String: Any]
        return object?["model"] as? String
    }

    /// `body` with its top-level `model` set to `model`; nil when the body isn't a JSON object.
    private static func replacingModel(in body: ByteBuffer, with model: String) -> ByteBuffer? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(buffer: body), options: [])) as? [String: Any]
        else { return nil }
        object["model"] = model
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return nil }
        return ByteBuffer(data: data)
    }

    /// Whether a `self` request could land on this Mac: it takes coordinator work, it serves the model (or a build of
    /// the alias the request names), and the coordinator counts no other Mac of the owner's serving it. A count the
    /// coordinator can't give counts as none, so the `self` hop is skipped (fail closed).
    private func selfHopWouldReturnHere(model: String, key: String) async -> Bool {
        guard config.takesCoordinatorWork else { return false }
        let local = Set(await localModels())
        var servedHere = local.contains(model)
        if !servedHere, let catalog = await catalog() {
            servedHere = !local.isDisjoint(with: catalog.builds(of: model))
        }
        guard servedHere else { return false }
        return (await ownedProviderCount(model: model, key: key) ?? 0) < 2
    }

    private func upstreamRequest(hop: LocalRouterUpstreamRoute, path: String, body: ByteBuffer,
                                 clientHeaders: HTTPFields, key: String) -> LocalRouterUpstreamRequest {
        // Only what the coordinator needs: the client's own key and route header are never forwarded.
        var headers = baseHeaders(key: key)
        headers[LocalRouterPolicy.routeHeader.rawName] = hop.rawValue
        headers["Content-Type"] = clientHeaders[.contentType] ?? "application/json"
        headers["Accept"] = clientHeaders[.accept] ?? "*/*"
        return LocalRouterUpstreamRequest(url: upstreamURL(path), method: "POST", headers: headers, body: body,
                                          connectTimeout: timing.connect, idleTimeout: timing.idle)
    }

    private func baseHeaders(key: String?) -> [String: String] {
        var headers = ["Accept-Encoding": "identity",
                       "User-Agent": "\(BuildEnvironment.current.cliName)-local-router/\(ProviderCore.version)"]
        // The one place the account key leaves its store: this header, to the configured coordinator only (the
        // transport follows no redirect).
        if let key { headers["Authorization"] = "Bearer " + key }
        return headers
    }

    private func upstreamURL(_ pathAndQuery: String) -> URL {
        URL(string: config.upstreamBaseURL.absoluteString + pathAndQuery) ?? config.upstreamBaseURL
    }

    /// A streamed or collected answer, passed through chunk by chunk as it arrives. A client that leaves stops the
    /// request at the coordinator (on `prefer` the network would go on generating, billed): when a chunk can't be
    /// written, and when its connection closes even while no chunk flows (the request's disconnect scope, which this
    /// Mac's own streams use too; the server allows half-close, so a client that only half-closes is noticed at the
    /// next chunk).
    private func relay(_ upstream: LocalRouterUpstreamResponse, hop: LocalRouterUpstreamRoute) -> Response {
        let body = upstream.body, cancel = upstream.cancel
        let scope = LocalRequestCancellation.current
        let registration = scope?.register(cancel)
        return Response(status: .init(code: upstream.status), headers: relayedHeaders(upstream, hop: hop),
                        body: ResponseBody { writer in
                            var ended = false
                            defer {
                                registration?.remove()
                                if !ended { cancel() }
                                withExtendedLifetime(scope) {}
                            }
                            for try await chunk in body { try await writer.write(chunk) }
                            try await writer.finish(nil)
                            ended = true
                        })
    }

    /// The coordinator's refusal as it sent it (status, body, `Retry-After`), with three exceptions: the account key is
    /// never echoed; a refused account key is this Mac's problem, not the client's (502, not 401); and a 402 on the
    /// network hop says first that it is the network fallback that needs a balance.
    private func relayError(_ upstream: LocalRouterUpstreamResponse, body: ByteBuffer?,
                            hop: LocalRouterUpstreamRoute, key: String) -> Response {
        guard var bytes = body else {
            var response = Self.errorResponse(.badGateway, message: "Darkbloom answered \(upstream.status) with an "
                + "error this Mac could not read.", code: "darkbloom_error_unreadable")
            response.headers[LocalRouterPolicy.routeUsedHeader] = hop.rawValue
            return response
        }
        bytes = Self.redacting(key, in: bytes)
        if upstream.status == 401 || upstream.status == 403 {
            log("Darkbloom refused the saved account key; save a new one with `\(BuildEnvironment.current.cliName) route key`")
            let detail = Self.errorMessage(in: bytes).map { " (\($0))" } ?? ""
            var response = Self.errorResponse(.badGateway, message: "Darkbloom refused this Mac's saved account key"
                + "\(detail). Save a new one with `\(BuildEnvironment.current.cliName) route key`.",
                code: "account_key_refused")
            response.headers[LocalRouterPolicy.routeUsedHeader] = hop.rawValue
            return response
        }
        if upstream.status == 402, hop == .prefer, let clarified = Self.prefixingMessage(in: bytes, with:
            "No balance for the network fallback: none of your Macs could take this request, and the Darkbloom "
            + "network needs a positive balance. Darkbloom said: ") {
            bytes = clarified
        }
        return Response(status: .init(code: upstream.status), headers: relayedHeaders(upstream, hop: hop),
                        body: .init(byteBuffer: bytes))
    }

    private func relayedHeaders(_ upstream: LocalRouterUpstreamResponse, hop: LocalRouterUpstreamRoute) -> HTTPFields {
        var headers = HTTPFields()
        // Never the coordinator's `X-Provider-Id`: the answer names no Mac.
        for name in ["content-type", "cache-control", "retry-after", "x-request-id", "x-inference-job-id"] {
            if let value = upstream.headers[name], let field = HTTPField.Name(name) { headers[field] = value }
        }
        headers[LocalRouterPolicy.servedByHeader] = LocalRouterPolicy.darkbloom
        headers[LocalRouterPolicy.routeUsedHeader] = hop.rawValue
        headers[.accessControlAllowOrigin] = "*"
        return headers
    }

    /// This Mac's refusal, said plainly, when its request was not passed on because only this Mac could take it.
    private func thisMacOnly(_ local: Response, model: String) -> Response {
        var response = Self.errorResponse(local.status, message: "This Mac can't take this request right now, and "
            + "none of your other Macs serves \(model), so it was not passed on.", code: "this_mac_only")
        if let retryAfter = local.headers[.retryAfter] { response.headers[.retryAfter] = retryAfter }
        response.headers[LocalRouterPolicy.servedByHeader] = LocalRouterPolicy.thisMac
        return response
    }

    // MARK: - Models

    func models<Inner: HTTPResponder>(_ request: Request, context: Inner.Context, inner: Inner) async throws -> Response {
        let local = try await inner.respond(to: request, context: context)
        guard local.status == .ok, let data = await Self.collect(local.body, limit: 4 * 1024 * 1024),
              let list = try? JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: data))
        else { return local }
        var localLimits: [String: LocalModelLimits] = [:]
        for entry in list.data { localLimits[entry.id] = await self.localLimits(entry.id) }
        var upstream: [(ownedBy: String, entries: [LocalRouterModelEntry])] = []
        var catalog: LocalRouterCatalog?
        let (route, key) = config.effectiveRoute()
        if let key {
            async let catalogRead = self.catalog()
            async let mine = upstreamModels(view: .mine, key: key)
            async let network = route == .myMacsFirst ? upstreamModels(view: .network, key: key) : []
            catalog = await catalogRead
            upstream = [(LocalRouterPolicy.myMacs, await mine), (LocalRouterPolicy.darkbloom, await network)]
        }
        let merged = LocalRouterModelMerge.merge(local: list.data, upstream: upstream, localLimits: localLimits,
                                                 catalog: catalog)
        let encoded = try JSONEncoder().encode(LocalRouterModelList(data: merged))
        return Response(status: .ok, headers: [.contentType: "application/json", .accessControlAllowOrigin: "*"],
                        body: .init(byteBuffer: ByteBuffer(data: encoded)))
    }

    /// The coordinator's model lists the router merges after this Mac's.
    enum UpstreamView: Sendable {
        /// The owner's live models, read with `X-Darkbloom-Route: self`: listed as `my-macs`.
        case mine
        /// The public list, which `prefer` falls back to: listed as `darkbloom`, with `my-macs-first` only.
        case network
    }

    /// The coordinator's model list for the owner (`self`) or the public one, cached for `listTTL`.
    private func upstreamModels(view: UpstreamView, key: String) async -> [LocalRouterModelEntry] {
        let cacheKey = "\(view)|" + Self.fingerprint(key)
        return await state.lists.value(for: cacheKey, ttl: timing.listTTL, failureTTL: timing.failureTTL) {
            let read = self.modelsRequest("/v1/models", key: key, route: view == .mine ? .mine : nil)
            guard let data = await self.get(read),
                  let list = try? JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: data))
            else { return nil }
            return list.data
        } ?? []
    }

    /// The Darkbloom catalog's limits and aliases (keyless), cached for `catalogTTL`. Read only when the route dials out.
    private func catalog() async -> LocalRouterCatalog? {
        await state.catalog.value(for: "catalog", ttl: timing.catalogTTL, failureTTL: timing.failureTTL) {
            guard let data = await self.get(self.modelsRequest("/v1/models/catalog?include_aliases=1", key: nil))
            else { return nil }
            return LocalRouterCatalog.decode(Data(buffer: data))
        }
    }

    /// How many of the owner's Macs serve `model` now, by the coordinator's `self` view of that one model (a Mac
    /// paused for its owner counts); 0 when none does; nil when the coordinator could not say.
    private func ownedProviderCount(model: String, key: String) async -> Int? {
        guard let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let transport = await state.transport(makeTransport)
        guard let response = try? await transport.send(modelsRequest("/v1/models/" + escaped, key: key, route: .mine))
        else { return nil }
        let body = await Self.collect(response.body, limit: 1024 * 1024)
        if response.status == 404 { return 0 }
        guard response.status == 200, let body,
              let entry = try? JSONDecoder().decode(LocalRouterOwnedModel.self, from: Data(buffer: body)) else { return nil }
        return entry.providerCount
    }

    /// A GET of one of the coordinator's model views, with `timing.list` to connect and between bytes: the account
    /// key (none for the keyless catalog) and, for the owner's own view, `X-Darkbloom-Route: self`.
    private func modelsRequest(_ pathAndQuery: String, key: String?, route: LocalRouterUpstreamRoute? = nil)
        -> LocalRouterUpstreamRequest {
        var headers = baseHeaders(key: key)
        headers["Accept"] = "application/json"
        if let route { headers[LocalRouterPolicy.routeHeader.rawName] = route.rawValue }
        return LocalRouterUpstreamRequest(url: upstreamURL(pathAndQuery), method: "GET", headers: headers, body: nil,
                                          connectTimeout: timing.list, idleTimeout: timing.list)
    }

    /// The body of a small GET when the coordinator answered 200, whole within `timing.list`; nil otherwise.
    private func get(_ request: LocalRouterUpstreamRequest) async -> ByteBuffer? {
        let transport = await state.transport(makeTransport)
        let deadline = timing.list
        return await withTaskGroup(of: ByteBuffer?.self) { group in
            group.addTask {
                guard let response = try? await transport.send(request), response.status == 200 else { return nil }
                return await Self.collect(response.body, limit: 4 * 1024 * 1024)
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Helpers

    /// The whole body, or nil past `limit` bytes or on a read error.
    static func collect(_ body: AsyncThrowingStream<ByteBuffer, Error>, limit: Int) async -> ByteBuffer? {
        var collected = ByteBuffer()
        do {
            for try await chunk in body {
                guard collected.readableBytes + chunk.readableBytes <= limit else { return nil }
                collected.writeImmutableBuffer(chunk)
            }
        } catch {
            return nil
        }
        return collected
    }

    /// A response body this Mac's engine made (a JSON list or error), read whole.
    static func collect(_ body: ResponseBody, limit: Int) async -> ByteBuffer? {
        let sink = CollectingBodySink(limit: limit)
        do {
            try await body.write(CollectingBodyWriter(sink: sink))
        } catch {
            return nil
        }
        return sink.buffer
    }

    static func errorResponse(_ status: HTTPResponse.Status, message: String, code: String? = nil) -> Response {
        var error: [String: Any] = ["message": message, "type": status.code >= 500 ? "server_error" : "invalid_request_error"]
        if let code { error["code"] = code }
        let data = (try? JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys]))
            ?? Data(#"{"error":{"message":"local router error","type":"server_error"}}"#.utf8)
        return Response(status: status, headers: [.contentType: "application/json", .accessControlAllowOrigin: "*"],
                        body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    static func redacting(_ key: String, in body: ByteBuffer) -> ByteBuffer {
        guard !key.isEmpty, let text = body.getString(at: body.readerIndex, length: body.readableBytes),
              text.contains(key) else { return body }
        return ByteBuffer(string: text.replacingOccurrences(of: key, with: "[account key]"))
    }

    static func errorMessage(in body: ByteBuffer) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    /// The same JSON error with `prefix` before its `message`; nil when the body is not an OpenAI error object.
    static func prefixingMessage(in body: ByteBuffer, with prefix: String) -> ByteBuffer? {
        guard var object = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
              var error = object["error"] as? [String: Any] else { return nil }
        error["message"] = prefix + ((error["message"] as? String) ?? "")
        object["error"] = error
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return ByteBuffer(data: data)
    }

    static func plain(_ error: Error) -> String {
        if let error = error as? LocalRouterUpstreamError { return error.description }
        return "Darkbloom could not be reached"
    }

    /// Cache identity of a key, so a new key reads anew. Never logged.
    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The router's mutable state: the upstream client, made by the first request that needs it, and the list caches.
private actor LocalRouterState {
    private var transport: (any LocalRouterTransport)?
    let lists = LocalRouterCache<[LocalRouterModelEntry]>()
    let catalog = LocalRouterCache<LocalRouterCatalog>()

    func transport(_ make: @Sendable () -> any LocalRouterTransport) -> any LocalRouterTransport {
        if let transport { return transport }
        let made = make()
        transport = made
        return made
    }
}

/// A small read-through cache: one read in flight per key, its result kept for `ttl` (a failure for `failureTTL`).
actor LocalRouterCache<Value: Sendable> {
    private struct Entry {
        let id: UUID
        let read: Task<Value?, Never>
        var expires: ContinuousClock.Instant?
    }
    private var entries: [String: Entry] = [:]

    func value(for key: String, ttl: Duration, failureTTL: Duration,
               read: @escaping @Sendable () async -> Value?) async -> Value? {
        if let entry = entries[key], entry.expires.map({ ContinuousClock.now < $0 }) ?? true {
            return await entry.read.value
        }
        let entry = Entry(id: UUID(), read: Task { await read() }, expires: nil)
        entries[key] = entry
        let value = await entry.read.value
        if entries[key]?.id == entry.id {
            entries[key]?.expires = ContinuousClock.now.advanced(by: value == nil ? failureTTL : ttl)
        }
        return value
    }
}

private final class CollectingBodySink: @unchecked Sendable {
    let limit: Int
    var buffer = ByteBuffer()
    init(limit: Int) { self.limit = limit }
}

private struct CollectingBodyWriter: ResponseBodyWriter {
    let sink: CollectingBodySink

    struct TooLarge: Error {}

    mutating func write(_ buffer: ByteBuffer) async throws {
        guard sink.buffer.readableBytes + buffer.readableBytes <= sink.limit else { throw TooLarge() }
        sink.buffer.writeImmutableBuffer(buffer)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}
