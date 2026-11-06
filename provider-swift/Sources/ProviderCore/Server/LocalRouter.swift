import Foundation
import HTTPTypes

/// The local router: this Mac's local API takes the owner's request first, then, when this Mac can't take it and the
/// owner chose so, passes it to the coordinator, the way the iPhone app routes:
///
/// | `[local] route`  | Hops                                                                            |
/// |------------------|---------------------------------------------------------------------------------|
/// | `this-mac`       | this Mac's engine only; the router never dials out                              |
/// | `my-macs`        | this Mac → the coordinator with `X-Darkbloom-Route: self` (the owner's Macs, free) |
/// | `my-macs-first`  | this Mac → `self` → `prefer` (the owner's Macs first, then the network, billed)  |
///
/// `self` comes before `prefer` because `prefer` needs a funded account even when the owner's own Mac answers
/// (402 at a zero balance). The coordinator orders "my other Macs, then others" itself.
///
/// A request this Mac serves never leaves the process: the router hands it to the engine and returns the engine's
/// response as it is, adding one header. The upstream client exists only once a request needs it.
public struct LocalRouterConfig: Sendable {
    /// The saved `[local]` settings; `route` decides the hops.
    public var settings: LocalSettings
    /// The coordinator's HTTP base URL (`LocalRouterPolicy.upstreamBaseURL`).
    public var upstreamBaseURL: URL
    /// This Mac takes Darkbloom work from the coordinator, so a `self` request could come back to it (`--local` and
    /// `cluster local` never do).
    public var takesCoordinatorWork: Bool
    public var accountKeys: any LocalRouterAccountKeyStore
    /// Makes the upstream client; called once, by the first request that needs the coordinator.
    public var makeTransport: @Sendable () -> any LocalRouterTransport
    /// One line per decision to pass a request on; never a key, a body or a prompt.
    public var log: @Sendable (String) -> Void
    public var timing: LocalRouter.Timing

    public init(settings: LocalSettings, upstreamBaseURL: URL, takesCoordinatorWork: Bool,
                accountKeys: any LocalRouterAccountKeyStore,
                makeTransport: @escaping @Sendable () -> any LocalRouterTransport = { URLSessionLocalRouterTransport() },
                log: @escaping @Sendable (String) -> Void = LocalRouter.standardErrorLog,
                timing: LocalRouter.Timing = .init()) {
        self.settings = settings
        self.upstreamBaseURL = upstreamBaseURL
        self.takesCoordinatorWork = takesCoordinatorWork
        self.accountKeys = accountKeys
        self.makeTransport = makeTransport
        self.log = log
        self.timing = timing
    }

    /// The router of a host: `[local]` from the config (absent = today's defaults), the configured coordinator, and
    /// the account key in the Keychain.
    public static func host(local: LocalSettings?, coordinatorURL: String?, takesCoordinatorWork: Bool,
                            accountKeys: any LocalRouterAccountKeyStore = KeychainLocalRouterAccountKeyStore())
        -> LocalRouterConfig {
        LocalRouterConfig(settings: local ?? LocalSettings(),
                          upstreamBaseURL: LocalRouterPolicy.upstreamBaseURL(coordinatorURL: coordinatorURL),
                          takesCoordinatorWork: takesCoordinatorWork, accountKeys: accountKeys)
    }

    /// The route in effect now, and the key it uses. Without a saved key nothing can go upstream, whatever the route.
    func effectiveRoute() -> (route: LocalSettings.Route, accountKey: String?) {
        if settings.route == .thisMac { return (.thisMac, nil) }
        let key = (try? accountKeys.load()).flatMap { $0.isEmpty ? nil : $0 }
        let route = settings.resolvedRoute(accountKeySaved: key != nil)
        guard let key, route != .thisMac else { return (.thisMac, nil) }
        return (route, key)
    }
}

/// The value of `X-Darkbloom-Route` on an upstream hop.
public enum LocalRouterUpstreamRoute: String, Sendable, Equatable {
    /// The owner's Macs only, free (EXCLUSIVE self-route).
    case mine = "self"
    /// The owner's Macs first, then the network, billed when the network answers (PREFER).
    case prefer
}

/// The router's decisions, pure.
public enum LocalRouterPolicy {
    public static let routeHeader = HTTPField.Name("X-Darkbloom-Route")!
    /// `this-mac` or `darkbloom`: who answered. Never a Mac's identity.
    public static let servedByHeader = HTTPField.Name("X-Darkbloom-Served-By")!
    /// `self` or `prefer` on an upstream answer: the route the router used.
    public static let routeUsedHeader = HTTPField.Name("X-Darkbloom-Route-Used")!

    /// The coordinator's HTTP base: `[coordinator] url` or `--coordinator-url` with `ws` → `http`, `wss` → `https` and
    /// the provider socket path dropped (`ws://h:8080/ws/provider` → `http://h:8080`); the build's coordinator otherwise.
    public static func upstreamBaseURL(coordinatorURL: String?) -> URL {
        let fallback = URL(string: BuildEnvironment.current.coordinatorHTTPURL)!
        let httpSchemes = ["ws": "http", "wss": "https", "http": "http", "https": "https"]
        guard let raw = coordinatorURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme.flatMap({ httpSchemes[$0.lowercased()] }),
              components.host?.isEmpty == false
        else { return fallback }
        components.scheme = scheme
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/ws/provider") { path.removeLast("/ws/provider".count) }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url ?? fallback
    }

    /// The coordinator path for a local inference path this router may pass on; nil for every other path, which
    /// only this Mac serves (models, health, tokenizer utilities, embeddings, batches, stored responses).
    public static func upstreamPath(forLocalPath path: String) -> String? {
        switch path {
        case "/v1/chat/completions", "/chat/completions": return "/v1/chat/completions"
        case "/v1/completions", "/completions": return "/v1/completions"
        case "/v1/responses", "/responses": return "/v1/responses"
        default: return nil
        }
    }

    public static func isModelsPath(_ path: String) -> Bool { path == "/v1/models" || path == "/models" }

    /// The upstream hops of a route, in order.
    public static func hops(for route: LocalSettings.Route) -> [LocalRouterUpstreamRoute] {
        switch route {
        case .thisMac: return []
        case .myMacs: return [.mine]
        case .myMacsFirst: return [.mine, .prefer]
        }
    }

    /// This Mac's answer passes the request on only when this Mac can't serve it, before any byte reached the client:
    /// the model isn't served here (404), or this Mac can't take it now (429 queue full; 503 for capacity, a drain,
    /// an add-on hold or a refused load). Client errors (400, 413, 422), a bad local key (401, answered before the
    /// router), a cancel (499) and engine failures (5xx but 503) stay this Mac's answer.
    public static func passesOn(localStatus status: HTTPResponse.Status) -> Bool {
        status == .notFound || status == .tooManyRequests || status == .serviceUnavailable
    }

    /// After `self`, `my-macs-first` tries `prefer` when no Mac of the owner's took the request: none linked (409),
    /// none online, none serving the model or none able to take its shape (503), or all busy (429, `machine_busy`).
    public static func triesNextHop(after status: Int) -> Bool {
        status == 409 || status == 429 || status == 503
    }

    /// `X-Darkbloom-Served-By` of this Mac's own answers.
    public static let thisMac = "this-mac"
    /// `X-Darkbloom-Served-By` of an upstream answer. Whether a `prefer` answer came from an owned Mac isn't known.
    public static let darkbloom = "darkbloom"
}
