import Foundation
import HTTPTypes
import notify

/// The local router: this Mac's local API takes the owner's request first, then, when this Mac can't take it and the
/// owner chose so, passes it to the coordinator, the way the iPhone app routes:
///
/// | `[local] route`  | Hops                                                                            |
/// |------------------|---------------------------------------------------------------------------------|
/// | `this-mac`       | this Mac's engine only; the router never dials out                                  |
/// | `my-macs`        | this Mac → the coordinator with `X-Darkbloom-Route: self` (the owner's Macs, free)   |
/// | `my-macs-first`  | this Mac → `prefer` (the owner's Macs first, then the network, billed); on a 402, `self` |
///
/// `prefer` lets the coordinator order "my other Macs, then others" itself, among the Macs that can take the request
/// now, so a busy Mac of the owner's doesn't hold it while another Mac, the owner's or the network's, can take it.
/// When none can, the coordinator queues `prefer` too: up to 120 s, and kept while the owner has a Mac serving the
/// model. `prefer` reserves the price up front even when the owner's own Mac answers (it charges nothing then), so
/// its 402 (no balance, or the key's spend cap) asks `self` once: free, the owner's Macs only, never spending.
/// A client on another machine never takes `prefer`: `my-macs-first` serves it as `my-macs` (`LocalRouterPolicy.route`).
///
/// A request this Mac serves never leaves the process: the router hands it to the engine and returns the engine's
/// response as it is, adding one header. The upstream client exists only once a request needs it.
public struct LocalRouterConfig: Sendable {
    /// The saved `[local]` settings; `route` decides the hops.
    public var settings: LocalSettings
    /// The provider config file `settings` came from. A running router reads its `[local] route` again when the file
    /// changes (`LocalRouterRouteFile`), so `darkbloom route <choice>` or an edit counts from the next request that
    /// needs the route, with no restart. nil: `settings.route` stays as given.
    public var settingsFile: URL?
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
    /// Whether the local API requires its key. Without one (`--no-auth`) anything that reaches the port is a client, so
    /// the router serves this Mac only and never reads or lends the account key. `makeLocalInferenceApplication` sets it
    /// from the endpoint's own key.
    public var localKeyRequired = true
    /// The Darwin notification the key store posts when `route key` saves or removes the key
    /// (`KeychainLocalRouterAccountKeyStore.changeNotification`); nil when the store posts none (an in-memory one).
    var keyChangeNotification: String?
    /// The account key as last read, kept until it changes.
    let keyCache = LocalRouterKeyCache()
    /// `[local] route` as `settingsFile` says it since it last changed.
    let routeFile = LocalRouterRouteFile()

    public init(settings: LocalSettings, settingsFile: URL? = nil, upstreamBaseURL: URL, takesCoordinatorWork: Bool,
                accountKeys: any LocalRouterAccountKeyStore,
                makeTransport: @escaping @Sendable () -> any LocalRouterTransport = { URLSessionLocalRouterTransport() },
                log: @escaping @Sendable (String) -> Void = LocalRouter.standardErrorLog,
                timing: LocalRouter.Timing = .init()) {
        self.settings = settings
        self.settingsFile = settingsFile
        self.upstreamBaseURL = upstreamBaseURL
        self.takesCoordinatorWork = takesCoordinatorWork
        self.accountKeys = accountKeys
        self.makeTransport = makeTransport
        self.log = log
        self.timing = timing
        keyChangeNotification = (accountKeys as? KeychainLocalRouterAccountKeyStore)?.changeNotification
    }

    /// The router of a host: `[local]` from the config at `settingsFile` (absent = today's defaults), read again when
    /// that file changes, the configured coordinator, and the account key in the Keychain.
    public static func host(local: LocalSettings?, settingsFile: URL?, coordinatorURL: String?, takesCoordinatorWork: Bool,
                            accountKeys: any LocalRouterAccountKeyStore = KeychainLocalRouterAccountKeyStore())
        -> LocalRouterConfig {
        LocalRouterConfig(settings: local ?? LocalSettings(), settingsFile: settingsFile,
                          upstreamBaseURL: LocalRouterPolicy.upstreamBaseURL(coordinatorURL: coordinatorURL),
                          takesCoordinatorWork: takesCoordinatorWork, accountKeys: accountKeys)
    }

    /// `[local] route` now: as `settingsFile` says it since it last changed, else as given.
    func savedRoute() -> LocalSettings.Route? {
        guard let settingsFile else { return settings.route }
        return routeFile.route(in: settingsFile, startingWith: settings.route, log: log)
    }

    /// The route in effect now, and the key it uses. Without a saved key, or without a local key (`--no-auth`), nothing
    /// can go upstream, whatever the route. The key is read once, by the first call that needs it, and kept in memory
    /// (`LocalRouterKeyCache`); `route key` announces a change, and the next call reads it again, so a change counts
    /// from the next request without a restart. A saved `this-mac`, or no local key, never reads the Keychain. A key
    /// that can't be read (the Keychain won't hand it over without asking) isn't kept: it is said once per run of
    /// failures, in a line without the key, and keeps requests on this Mac. `[local] route` counts from the next call
    /// after the config file changes (`savedRoute`). Only a request this Mac can't take, and a model list, call this.
    func effectiveRoute() -> (route: LocalSettings.Route, accountKey: String?) {
        guard localKeyRequired else { return (.thisMac, nil) }
        let saved = settings.route
        guard saved != .thisMac else { return (.thisMac, nil) }
        let key: String?
        do {
            key = try keyCache.key(from: accountKeys, changes: keyChangeNotification)
        } catch {
            if keyCache.readFailed() {
                // Only the store's own error is known to carry no key characters (an OSStatus only).
                let reason = (error as? LocalRouterAccountKeyError)?.description ?? "the account key could not be read"
                log("\(reason); requests stay on this Mac until it can be read (after a new build, save it again with "
                    + "`\(BuildEnvironment.current.cliName) route key`)")
            }
            return (.thisMac, nil)
        }
        let route = LocalSettings(route: saved).resolvedRoute(accountKeySaved: key != nil)
        guard let key, route != .thisMac else { return (.thisMac, nil) }
        return (route, key)
    }
}

// Seam for the red tests of a live route, with today's behaviour: the router reads `[local] route` at start only.
final class LocalRouterRouteFile: @unchecked Sendable {
    var checks: Int { 0 }

    func route(in file: URL, startingWith initial: LocalSettings.Route?, log: (String) -> Void,
               read: (URL) throws -> LocalSettings.Route? = { _ in nil }) -> LocalSettings.Route? {
        initial
    }
}

/// The account key as last read, kept in memory so passed-on requests and model lists don't each read the Keychain.
///
/// The copy is kept only while the store's changes are watched: the store posts a Darwin notification when `route key`
/// saves or removes the key, and this drops the copy on it (`notify_register_dispatch`), so the next request reads the
/// key again. A failed read isn't kept, so the next request tries again; a run of failures is said once.
final class LocalRouterKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    /// nil: no copy; `.some(nil)`: read, and no key is saved.
    private var copy: String??
    /// How many changes were announced, so a read that a change overtook isn't kept.
    private var changes = 0
    private var failing = false
    private var watchTried = false
    /// The registration for the change notification; nil when there is none to watch, or it couldn't be made.
    private var watch: Int32?

    deinit { if let watch { notify_cancel(watch) } }

    /// Whether a copy is kept now.
    var keepsACopy: Bool { lock.withLock { copy != nil } }

    /// The saved key, nil when none is saved: the kept copy, else a read of `store`, kept while `changes` (the store's
    /// change notification) is watched.
    func key(from store: any LocalRouterAccountKeyStore, changes notification: String?) throws -> String? {
        let (kept, seen, keeps) = lock.withLock { () -> (String??, Int, Bool) in
            if !watchTried {
                watchTried = true
                watch = notification.flatMap { watchChanges(named: $0) }
            }
            return (copy, changes, watch != nil)
        }
        if let kept { return kept }
        let key = try store.load().flatMap { $0.isEmpty ? nil : $0 }
        lock.withLock {
            failing = false
            if keeps, changes == seen { copy = .some(key) }
        }
        return key
    }

    /// The key changed: the next request reads it again.
    func drop() {
        lock.withLock {
            copy = nil
            changes += 1
        }
    }

    /// Notes a failed read; true when it starts a run of failures.
    func readFailed() -> Bool {
        lock.withLock {
            defer { failing = true }
            return !failing
        }
    }

    /// Registers for `name`; nil when it can't, and then nothing is kept.
    private func watchChanges(named name: String) -> Int32? {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { [weak self] _ in
            self?.drop()
        }
        return status == NOTIFY_STATUS_OK ? token : nil
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

    /// The route for a request's client. One on another machine never takes the paid hop (`prefer`): whoever holds the
    /// local API's key there may use this Mac and the owner's other Macs (`self`, free), never the owner's balance. So
    /// `my-macs-first` serves it as `my-macs`; a program on this Mac gets the route as saved.
    public static func route(_ route: LocalSettings.Route, fromAnotherMachine: Bool) -> LocalSettings.Route {
        fromAnotherMachine && route == .myMacsFirst ? .myMacs : route
    }

    /// The upstream hop a request this Mac can't take is sent on, by route. `my-macs-first` asks `self` too, once, but
    /// only after `prefer` answered 402 (`asksYourMacs`).
    public static func hops(for route: LocalSettings.Route) -> [LocalRouterUpstreamRoute] {
        switch route {
        case .thisMac: return []
        case .myMacs: return [.mine]
        case .myMacsFirst: return [.prefer]
        }
    }

    /// This Mac's answer passes the request on only when this Mac can't serve it, before any byte reached the client:
    /// the model isn't served here (404), or this Mac can't take it now (429 queue full; 503 for capacity, a drain,
    /// an add-on hold or a refused load). Client errors (400, 413, 422), a bad local key (401, answered before the
    /// router), a cancel (499) and engine failures (5xx but 503) stay this Mac's answer.
    public static func passesOn(localStatus status: HTTPResponse.Status) -> Bool {
        status == .notFound || status == .tooManyRequests || status == .serviceUnavailable
    }

    /// `my-macs-first` asks the owner's Macs (`self`) once when `prefer` answered 402: its admission refused the
    /// request for money (no balance, the key's spend cap, a promotion's limit), even when an owned Mac would have
    /// answered. `self` never spends, so it may still take it.
    public static func asksYourMacs(afterNetworkStatus status: Int) -> Bool {
        status == 402
    }

    /// The words before Darkbloom's own message when `prefer`'s 402 stands (none of the owner's Macs took the request
    /// either), by its `error.type`: only `insufficient_funds` is a balance problem. Any other 402 (the key's spend
    /// cap, a promotion's limit) is left to Darkbloom's own message, which names it.
    static func networkRefusalPrefix(errorType: String?) -> String {
        errorType == "insufficient_funds"
            ? "No balance for the network fallback: none of your Macs could take this request, and the Darkbloom "
                + "network needs a positive balance. Darkbloom said: "
            : "Network fallback refused: none of your Macs could take this request, and Darkbloom would not send it "
                + "to the network. Darkbloom said: "
    }

    /// `self`'s answer when none of the owner's Macs took the request: none linked (409), none online, none serving
    /// the model or none able to take its shape (503), or all busy (429, `machine_busy`). The network's 402 then
    /// stands, as the clearer answer.
    public static func yourMacsCouldNotTakeIt(status: Int) -> Bool {
        status == 409 || status == 429 || status == 503
    }

    /// `X-Darkbloom-Served-By` of this Mac's own answers, and `owned_by` of the models this Mac serves.
    public static let thisMac = "this-mac"
    /// `owned_by` of the models the owner's other Macs serve (the coordinator's `self` list).
    public static let myMacs = "my-macs"
    /// `X-Darkbloom-Served-By` of an upstream answer, and `owned_by` of the network's models. Whether a `prefer` answer
    /// came from an owned Mac isn't known, so it isn't claimed.
    public static let darkbloom = "darkbloom"
}
