import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import MLXLMServer
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// The local API bounds a request by the route the SDK router resolves it to (`LocalRoute`, `LocalIngress`). The
/// router drops empty path segments, so `/v1/chat/completions/` and `//v1/chat/completions` are the route
/// `/v1/chat/completions`; and a route nobody gave limits of its own keeps the default ones. The routes come from
/// the router itself, so one a later SDK registers joins every table here.
@Suite("Local API ingress")
struct LocalIngressTests {
    // MARK: - The table

    /// A way to write a route's path that the router resolves to that same route.
    enum Spelling: String, CaseIterable, Sendable {
        case exact, trailingSlash, leadingSlashDoubled, innerSlashDoubled

        func of(_ path: String) -> String {
            switch self {
            case .exact: return path
            case .trailingSlash: return path + "/"
            case .leadingSlashDoubled: return "/" + path
            case .innerSlashDoubled:
                guard let slash = path.lastIndex(of: "/") else { return path }
                return path[..<slash] + "//" + path[path.index(after: slash)...]
            }
        }
    }

    /// A body no route may hand to a parser or a model.
    enum OverLimit: String, CaseIterable, Sendable {
        case nestedPastTheLimit, nulByte, pastTheBodyCeiling
        /// One request more than a list may hold: left unchecked, it reaches the model.
        case tooManyItems
        /// As many values that are no requests: refused for their count, so counted before any is decoded.
        case tooManyItemsThatDoNotDecode
        /// Both lists behind a UTF-8 byte-order mark, which the parsers skip: counted all the same.
        case tooManyItemsBehindAByteOrderMark, tooManyItemsThatDoNotDecodeBehindAByteOrderMark

        var isAListTooLong: Bool {
            switch self {
            case .nestedPastTheLimit, .nulByte, .pastTheBodyCeiling: return false
            case .tooManyItems, .tooManyItemsThatDoNotDecode, .tooManyItemsBehindAByteOrderMark,
                 .tooManyItemsThatDoNotDecodeBehindAByteOrderMark: return true
            }
        }
    }

    struct Route: Sendable, CustomStringConvertible {
        let method: HTTPRequest.Method
        /// As the router registered it, a capture written `{name}`.
        let pattern: String
        /// `pattern` with a value for each capture.
        let path: String
        var readsNoBody: Bool { method == .get || method == .head }
        var description: String { "\(method) \(pattern)" }
    }

    /// What a client is told. Two spellings of one route must be told the same.
    struct Answer: Equatable, Sendable, CustomStringConvertible {
        var status: Int
        var message: String?
        var code: String?
        var servedBy: String?
        var description: String {
            "\(status) message=\(message ?? "nil") code=\(code ?? "nil") served-by=\(servedBy ?? "nil")"
        }
    }

    /// How many times a model was asked for.
    actor Acquisitions {
        var count = 0
        func mark() { count += 1 }
    }

    static let key = "synthetic-fixture-token"
    static let megabyte = 1024 * 1024
    static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The routes whose body ceiling is raised above the default 2 MiB, by the pattern the router registered. Every
    /// other route, today's or a later SDK's, is held to the default.
    static let raisedCeilingMiB = ["/v1/chat/completions": 32, "/chat/completions": 32, "/v1/chat/completions/batch": 32]
    /// The routes whose body is a list with a bound on its length.
    static let itemLimits = ["/v1/chat/completions/batch": 64]

    static func sdkRouter() -> Router<BasicRequestContext> {
        MLXServerApplication.buildRouter(service: MLXOpenAIService(engine: UnreachedEngine()))
    }

    /// Every route the local API's router registers, read from the router.
    static func registeredRoutes() -> [Route] {
        sdkRouter().routes.map { route in
            let segments = route.path.components.map { element -> String in
                let text = element.description
                return text.hasPrefix("{") ? "resp_fixture" : text
            }
            return Route(method: route.method, pattern: route.path.description, path: "/" + segments.joined(separator: "/"))
        }
    }

    /// Members that make one object a request every body route decodes.
    static let members = #""model":"fixture","messages":[{"role":"user","content":"hi"}],"input":"hi","prompt":"hi","#
        + #""content":"hi","tokens":[1]"#

    /// A request object that opens `levels` objects and arrays at once.
    static func nested(_ levels: Int) -> String {
        "{" + members + #","nested":"# + String(repeating: "[", count: levels - 1)
            + String(repeating: "]", count: levels - 1) + "}"
    }

    static func body(_ overLimit: OverLimit, ceilingMiB: Int = 2, itemLimit: Int = 64) throws -> ByteBuffer {
        switch overLimit {
        case .nestedPastTheLimit:
            return ByteBuffer(string: nested(JSONNestingLimit.maximumDepth + 1))
        case .nulByte:
            // Foundation's parsers read UTF-16 JSON, every byte pair of which here holds a NUL.
            return ByteBuffer(data: try #require(("{" + members + "}").data(using: .utf16LittleEndian)))
        case .tooManyItems:
            return ByteBuffer(string: "[" + Array(repeating: "{" + members + "}", count: itemLimit + 1)
                .joined(separator: ",") + "]")
        case .tooManyItemsThatDoNotDecode:
            return ByteBuffer(string: "[" + Array(repeating: "1", count: itemLimit + 1).joined(separator: ",") + "]")
        case .tooManyItemsBehindAByteOrderMark, .tooManyItemsThatDoNotDecodeBehindAByteOrderMark:
            let unmarked: OverLimit = overLimit == .tooManyItemsBehindAByteOrderMark ? .tooManyItems
                : .tooManyItemsThatDoNotDecode
            var list = try body(unmarked, itemLimit: itemLimit)
            var marked = ByteBuffer(bytes: byteOrderMark)
            marked.writeBuffer(&list)
            return marked
        case .pastTheBodyCeiling:
            return ByteBuffer(repeating: UInt8(ascii: " "), count: ceilingMiB * megabyte + 1)
        }
    }

    static func answer(_ response: TestResponse) -> Answer {
        let error = ((try? JSONSerialization.jsonObject(with: Data(buffer: response.body))) as? [String: Any])?["error"]
            as? [String: Any]
        return Answer(status: response.status.code, message: error?["message"] as? String,
                      code: error?["code"] as? String, servedBy: response.headers[LocalRouterPolicy.servedByHeader])
    }

    static func application(router: LocalRouterConfig?, acquisitions: Acquisitions) -> LocalInferenceApplication {
        makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: key, router: router),
            defaultMaxTokens: 32,
            acquire: { id in
                await acquisitions.mark()
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id)
            },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { ["fixture"] }, mtpSlots: { [] })
    }

    static let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer \(key)"]

    // MARK: - Every route, every spelling

    /// With and without the local router, whose own check answers the routes it may pass on.
    @Test(arguments: [false, true])
    func everyBodyRouteRefusesAnOverLimitBodyOnEverySpellingOfItsPath(routed: Bool) async throws {
        let routes = Self.registeredRoutes().filter { !$0.readsNoBody }
        // The router lists what the SDK serves; a list that lost the routes below would make this table vacuous.
        for served in ["/v1/chat/completions", "/v1/chat/completions/batch", "/v1/completions", "/v1/responses",
                       "/v1/responses/{response_id}/cancel", "/tokenize", "/apply-template", "/v1/embeddings"] {
            #expect(routes.contains { $0.pattern == served && $0.method == .post }, "\(served)")
        }
        let acquisitions = Acquisitions()
        let fixture = RouterFixture(route: .myMacs)
        let app = Self.application(router: routed ? fixture.routerConfig : nil, acquisitions: acquisitions)
        try await app.test(.router) { client in
            for route in routes {
                let ceilingMiB = Self.raisedCeilingMiB[route.pattern] ?? 2
                for overLimit in OverLimit.allCases {
                    let itemLimit = Self.itemLimits[route.pattern]
                    // A list is over a limit only where the route bounds its length.
                    if overLimit.isAListTooLong, itemLimit == nil { continue }
                    let body = try Self.body(overLimit, ceilingMiB: ceilingMiB, itemLimit: itemLimit ?? 64)
                    var exact: Answer?
                    for spelling in Spelling.allCases {
                        let answer = try await client.execute(uri: spelling.of(route.path), method: route.method,
                                                              headers: Self.headers, body: body, testCallback: Self.answer)
                        let row: Comment = "\(route) \(spelling.rawValue) \(overLimit.rawValue): \(answer)"
                        switch overLimit {
                        case .nestedPastTheLimit, .nulByte:
                            #expect(answer.status == 400, row)
                            #expect(answer.message == JSONNestingLimit.refusalMessage, row)
                        case .tooManyItems, .tooManyItemsThatDoNotDecode, .tooManyItemsBehindAByteOrderMark,
                             .tooManyItemsThatDoNotDecodeBehindAByteOrderMark:
                            #expect(answer.status == 400, row)
                            #expect(answer.code == "batch_too_large", row)
                            #expect(answer.message == "batch exceeds the \(itemLimit ?? 0)-request local endpoint limit", row)
                        case .pastTheBodyCeiling:
                            #expect(answer.status == 413, row)
                            #expect(answer.message == "request body exceeds the \(ceilingMiB) MiB local endpoint limit", row)
                        }
                        if let exact { #expect(answer == exact, row) } else { exact = answer }
                    }
                }
            }
        }
        #expect(await acquisitions.count == 0)
        #expect(fixture.upstream.requests.isEmpty)
    }

    /// `LocalIngress` leaves a GET's body unread because no GET route reads one: each answers a request the same
    /// with an over-limit body as with none.
    @Test func noGetRouteReadsABody() async throws {
        let routes = Self.registeredRoutes().filter(\.readsNoBody)
        #expect(routes.contains { $0.pattern == "/v1/models" } && routes.contains { $0.pattern == "/health" })
        let acquisitions = Acquisitions()
        let app = Self.application(router: nil, acquisitions: acquisitions)
        try await app.test(.router) { client in
            for route in routes {
                for spelling in Spelling.allCases {
                    let uri = spelling.of(route.path)
                    let bare = try await client.execute(uri: uri, method: route.method, headers: Self.headers,
                                                        testCallback: Self.answer)
                    for overLimit in OverLimit.allCases {
                        let answer = try await client.execute(
                            uri: uri, method: route.method, headers: Self.headers,
                            body: try Self.body(overLimit), testCallback: Self.answer)
                        #expect(answer.status == bare.status, "\(route) \(spelling.rawValue) \(overLimit.rawValue): \(answer)")
                    }
                }
            }
        }
        #expect(await acquisitions.count == 0)
    }

    /// The table above is not refusing everything, and a spelling keeps its route's raised ceiling: a chat body at
    /// the nesting limit and past the default 2 MiB is served on every spelling, and reaches the model, whose
    /// absence answers it.
    @Test func aBodyWithinItsRoutesLimitsIsServedOnEverySpelling() async throws {
        let acquisitions = Acquisitions()
        let app = Self.application(router: nil, acquisitions: acquisitions)
        let atTheNestingLimit = Self.nested(JSONNestingLimit.maximumDepth)
        let pastTheDefaultCeiling = atTheNestingLimit.dropLast() + #","padding":""#
            + String(repeating: "a", count: 3 * Self.megabyte) + #""}"#
        try await app.test(.router) { client in
            for spelling in Spelling.allCases {
                let answer = try await client.execute(uri: spelling.of("/v1/chat/completions"), method: .post,
                                                      headers: Self.headers, body: ByteBuffer(string: pastTheDefaultCeiling),
                                                      testCallback: Self.answer)
                #expect(answer.status == 404, "\(spelling.rawValue): \(answer)")
            }
        }
        #expect(await acquisitions.count == Spelling.allCases.count)
    }

    /// The spellings reach the server as written: over a real connection the answers are the in-process ones.
    @Test func theSpellingsAreRefusedOverARealConnection() async throws {
        let acquisitions = Acquisitions()
        let app = Self.application(router: nil, acquisitions: acquisitions)
        let body = try Self.body(.nestedPastTheLimit, ceilingMiB: 32)
        try await app.test(.live) { client in
            for spelling in Spelling.allCases {
                let answer = try await client.execute(uri: spelling.of("/v1/chat/completions"), method: .post,
                                                      headers: Self.headers, body: body, testCallback: Self.answer)
                #expect(answer.status == 400, "\(spelling.rawValue): \(answer)")
                #expect(answer.message == JSONNestingLimit.refusalMessage, "\(spelling.rawValue): \(answer)")
            }
        }
        #expect(await acquisitions.count == 0)
    }

    /// The checks a route runs on its decoded body hold on every spelling too: tool-call `arguments` nested past
    /// the limit, which the body scan skips, are refused wherever a template would render them.
    @Test func toolCallArgumentsAreRefusedOnEverySpelling() async throws {
        let deep = #"{"model":"fixture","# + InboundJSONDepthTests.messagesField(argumentNesting: 65) + "}"
        let nesting = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        let responses = #"{"model":"fixture","input":[{"type":"function_call","call_id":"c1","name":"f","arguments":""#
            + nesting + #""},{"type":"function_call_output","call_id":"c1","output":"ok"}]}"#
        let acquisitions = Acquisitions()
        let app = Self.application(router: nil, acquisitions: acquisitions)
        try await app.test(.router) { client in
            for (path, body) in [("/v1/chat/completions", deep), ("/v1/chat/completions/batch", "[" + deep + "]"),
                                 ("/v1/responses", responses), ("/apply-template", deep)] {
                for spelling in Spelling.allCases {
                    let answer = try await client.execute(uri: spelling.of(path), method: .post, headers: Self.headers,
                                                          body: ByteBuffer(string: body), testCallback: Self.answer)
                    #expect(answer.status == 400, "\(path) \(spelling.rawValue): \(answer)")
                    #expect(answer.message == JSONNestingLimit.argumentsRefusalMessage, "\(path) \(spelling.rawValue): \(answer)")
                }
            }
        }
        #expect(await acquisitions.count == 0)
    }

    /// A request no route was given limits for, here one no route serves at all, keeps the default ones; within
    /// them it gets the router's own answer.
    @Test func aRequestNoRouteServesKeepsTheDefaultLimits() async throws {
        let acquisitions = Acquisitions()
        let app = Self.application(router: nil, acquisitions: acquisitions)
        try await app.test(.router) { client in
            for (method, path) in [(HTTPRequest.Method.post, "/v1/unserved"), (.put, "/v1/chat/completions"),
                                   (.delete, "/v1/responses/resp_fixture")] {
                for overLimit in [OverLimit.nestedPastTheLimit, .nulByte, .pastTheBodyCeiling] {
                    let answer = try await client.execute(uri: path, method: method, headers: Self.headers,
                                                          body: try Self.body(overLimit), testCallback: Self.answer)
                    #expect(answer.status == (overLimit == .pastTheBodyCeiling ? 413 : 400), "\(method) \(path): \(answer)")
                }
                let answer = try await client.execute(uri: path, method: method, headers: Self.headers,
                                                      body: ByteBuffer(string: "{" + Self.members + "}"),
                                                      testCallback: Self.answer)
                #expect(answer.status == 404, "\(method) \(path): \(answer)")
            }
        }
        #expect(await acquisitions.count == 0)
    }

    // MARK: - The local router

    /// A request this Mac can't take is passed on from every spelling of a routed path, to the coordinator's own
    /// path; and the model list is the router's merged one on every spelling.
    @Test func theLocalRouterRoutesEverySpellingOfARoutedPath() async throws {
        let fixture = RouterFixture(route: .myMacs)
        let bodies = ["/v1/chat/completions": RouterFixture.chat("absent"),
                      "/v1/completions": #"{"model":"absent","prompt":"hi"}"#,
                      "/v1/responses": #"{"model":"absent","input":"hi"}"#]
        try await fixture.app.test(.router) { client in
            for (path, body) in bodies.sorted(by: { $0.key < $1.key }) {
                for spelling in Spelling.allCases {
                    try await client.execute(uri: spelling.of(path), method: .post, headers: RouterFixture.authorized,
                                             body: ByteBuffer(string: body)) { response in
                        #expect(response.status == .ok, "\(path) \(spelling.rawValue)")
                        #expect(response.headers[LocalRouterPolicy.servedByHeader] == "darkbloom", "\(path) \(spelling.rawValue)")
                    }
                }
            }
            for path in ["/v1/models", "/models"] {
                for spelling in Spelling.allCases {
                    try await client.execute(uri: spelling.of(path), method: .get, headers: RouterFixture.authorized) { response in
                        let list = try JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: response.body))
                        #expect(!list.data.isEmpty && list.data.allSatisfy { $0.ownedBy == LocalRouterPolicy.thisMac },
                                "\(path) \(spelling.rawValue)")
                    }
                }
            }
        }
        #expect(fixture.upstream.posts.map(\.url.path)
            == bodies.keys.sorted().flatMap { Array(repeating: $0, count: Spelling.allCases.count) })
    }

    // MARK: - LocalRoute

    /// `LocalRoute` reads a path the way the router's trie does. For every registered route and every way of
    /// writing its path, resolving or not, the real router says which route the request is; `LocalRoute` gives a
    /// request the router resolves the route of that route's own path, and one it doesn't resolve no route.
    @Test func aRouteIsResolvedAsTheRouterResolvesIt() async throws {
        let responder = Self.sdkRouter().buildResponder()
        /// The pattern of the route the router resolves a request to; nil when it resolves none.
        func resolved(_ request: Request) async -> String? {
            let context = BasicRequestContext(source: ApplicationRequestContextSource(
                channel: EmbeddedChannel(), logger: Logger(label: "local-ingress-tests")))
            _ = try? await responder.respond(to: request, context: context)
            return context.endpointPath == "NotFound" ? nil : context.endpointPath
        }
        // No rewriting writes a byte outside ASCII: over a connection the HTTP parser answers such a target 400
        // before any responder, and built here Hummingbird's `URI` traps on one ending in a three-byte character.
        let rewritings: [(name: String, resolves: Bool?, of: @Sendable (String) -> String)] = [
            ("exact", true, { $0 }),
            ("trailing slash", true, { $0 + "/" }),
            ("leading slash doubled", true, { "/" + $0 }),
            ("inner slash doubled", true, { Spelling.innerSlashDoubled.of($0) }),
            ("every slash tripled", true, { $0.replacingOccurrences(of: "/", with: "///") + "///" }),
            ("no leading slash", true, { String($0.dropFirst()) }),
            ("query", true, { $0 + "?stream=true" }),
            ("upper case", false, { $0.uppercased() }),
            ("one more segment", false, { $0 + "/zz" }),
            ("dot segment", false, { "/." + $0 }),
            ("dot-dot segment", false, { "/zz/.." + $0 }),
            // A capture takes these as part of its value, so only a route without one fails to resolve them.
            ("encoded slash", nil, { $0 + "%2F" }),
            ("encoded last letter", nil, { $0.dropLast() + String(format: "%%%02X", $0.utf8.last ?? 0) }),
            ("fragment", nil, { $0 + "#fragment" }),
        ]
        let routes = Self.registeredRoutes()
        for route in routes {
            for rewriting in rewritings {
                let request = Request(head: .init(method: route.method, scheme: "http", authority: "localhost",
                                                  path: rewriting.of(route.path)), body: .init(buffer: ByteBuffer()))
                let pattern = await resolved(request)
                let row: Comment = "\(route) \(rewriting.name): \(request.uri.path) resolves to \(pattern ?? "no route")"
                if let resolves = rewriting.resolves { #expect((pattern == route.pattern) == resolves, row) }
                // The route the router resolved, read by its own path as the router registered it.
                let registered = routes.first { $0.method == route.method && $0.pattern == pattern }
                let expected = registered.map { LocalRoute(method: $0.method, path: $0.path) } ?? .other
                #expect(LocalRoute(method: request.method, path: request.uri.path) == expected, row)
            }
        }
    }

    /// The limits each route has today, by the paths that name it.
    @Test func eachRouteKeepsItsLimits() {
        let twoMiB = 2 * 1024 * 1024, thirtyTwoMiB = 32 * 1024 * 1024
        let expected: [(method: HTTPRequest.Method, paths: [String], route: LocalRoute, ceiling: Int, items: Int?,
                        upstream: String?)] = [
            (.post, ["/v1/chat/completions", "/chat/completions"], .chatCompletions, thirtyTwoMiB, nil, "/v1/chat/completions"),
            (.post, ["/v1/chat/completions/batch"], .chatCompletionsBatch, thirtyTwoMiB, 64, nil),
            (.post, ["/v1/responses", "/responses"], .responses, twoMiB, nil, "/v1/responses"),
            (.post, ["/v1/completions", "/completions"], .completions, twoMiB, nil, "/v1/completions"),
            (.post, ["/apply-template"], .applyTemplate, twoMiB, nil, nil),
            (.get, ["/v1/models", "/models"], .models, twoMiB, nil, nil),
            (.post, ["/completion", "/tokenize", "/detokenize", "/v1/embeddings", "/embeddings", "/embedding",
                     "/v1/responses/resp_fixture/cancel", "/v1/unserved", "/", ""], .other, twoMiB, nil, nil),
            // A route is a method and a path: another method on a route's path is not that route.
            (.get, ["/v1/chat/completions", "/v1/chat/completions/batch", "/v1/responses", "/apply-template"],
             .other, twoMiB, nil, nil),
            (.post, ["/v1/models"], .other, twoMiB, nil, nil),
        ]
        for row in expected {
            for path in row.paths {
                let route = LocalRoute(method: row.method, path: path)
                #expect(route == row.route, "\(row.method) \(path)")
                #expect(route.bodyCeiling == row.ceiling, "\(row.method) \(path)")
                #expect(route.maxItems == row.items, "\(row.method) \(path)")
                #expect(route.upstreamPath == row.upstream, "\(row.method) \(path)")
            }
        }
        #expect(LocalIngress.defaultBodyCeiling == twoMiB)
    }

    // MARK: - The item count

    /// A list is never counted shorter than the parser that reads it next finds it, or its items are decoded before
    /// their number is refused. Foundation's parsers skip a UTF-8 byte-order mark before the text, so the count does
    /// too. A trailing comma, which they allow, counts one item more: the count errs toward refusing.
    @Test func aListIsNeverCountedShorterThanItsParsersReadIt() {
        struct AnyItem: Decodable { init(from decoder: Decoder) throws {} }
        let whitespace = Array(" \t\r\n".utf8)
        let prefixes: [(name: String, bytes: [UInt8])] = [
            ("nothing", []), ("whitespace", whitespace), ("a byte-order mark", Self.byteOrderMark),
            ("a byte-order mark, whitespace", Self.byteOrderMark + whitespace),
            // No JSON to the parsers, so no list to count.
            ("whitespace, a byte-order mark", whitespace + Self.byteOrderMark),
            ("two byte-order marks", Self.byteOrderMark + Self.byteOrderMark),
        ]
        // An item whose strings and nested values hold what separates and closes a list.
        let item = #"{"a":["x,]\"[",{"b":[1,2]}],"c":"}"}"#
        let lists: [(text: String, exact: Bool)] = [0, 1, 2, 64, 65].map {
            ("[" + Array(repeating: item, count: $0).joined(separator: " , ") + "]", true)
        } + [("[1,2,]", false)]
        var readBehindAMark = 0
        for prefix in prefixes {
            for list in lists {
                let bytes = prefix.bytes + Array(list.text.utf8)
                let counted = LocalIngress.itemCount(ByteBuffer(bytes: bytes))
                let row: Comment = "after \(prefix.name): \(list.text.prefix(24)) counted \(counted)"
                let serialized = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [Any]
                let decoded = try? JSONDecoder().decode([AnyItem].self, from: Data(bytes))
                for read in [serialized?.count, decoded?.count].compactMap({ $0 }) {
                    if list.exact { #expect(counted == read, row) } else { #expect(counted >= read, row) }
                    if prefix.bytes.starts(with: Self.byteOrderMark) { readBehindAMark += 1 }
                }
            }
        }
        // The parsers do read a list behind a mark: without that the rows above would say nothing of one.
        #expect(readBehindAMark > 0)
        let overTheBound = "[" + Array(repeating: "1", count: 65).joined(separator: ",") + "]"
        #expect(LocalIngress.itemCount(ByteBuffer(bytes: Self.byteOrderMark + Array(overTheBound.utf8))) == 65)
        // The nesting scan reads every byte and has no such blind spot.
        #expect(JSONNestingLimit.refuses(ByteBuffer(bytes: Self.byteOrderMark
            + Array(Self.nested(JSONNestingLimit.maximumDepth + 1).utf8))))
    }
}

/// Builds the SDK router whose routes are read; no request reaches a model through it.
private struct UnreachedEngine: MLXServerEngine {
    struct Unreached: Error {}
    func availableModels() async throws -> [MLXServerModel] { [] }
    func streamChatCompletion(request: OpenAIChatCompletionRequest)
        async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> { throw Unreached() }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { throw Unreached() }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { throw Unreached() }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { throw Unreached() }
}
