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
    /// The saved `[local]` settings at start; `route` decides the hops until `settingsFile` says another.
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
    /// Where the router's lines go: its decisions to pass requests on and the saved route's changes; never a key, a
    /// body, a prompt or text from the config file.
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
    /// `[local] route` as `settingsFile` said it when it last changed.
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

    /// `[local] route` now: as `settingsFile` says it (`LocalRouterRouteFile`), else as the router started with.
    func savedRoute() -> LocalSettings.Route? {
        guard let settingsFile else { return settings.route }
        return routeFile.route(in: settingsFile, startingWith: settings.route, log: log)
    }

    /// The route in effect now, and the key it uses; `.thisMacOnly` whenever nothing may leave this Mac.
    ///
    /// - Only a request this Mac can't take, and a model list, call this, once each. A request this Mac serves never
    ///   looks at the config file or the Keychain, and nothing here runs per token. A request passed on keeps, through
    ///   every hop, the route and key this call gave it, whatever an edit says meanwhile.
    /// - Without a local key (`--no-auth`), anything that reaches the port is a client: nothing is passed on, and
    ///   neither the file nor the Keychain is looked at.
    /// - The route is `[local] route` as the config file says it now (`savedRoute`); a saved `this-mac` never reads the
    ///   Keychain.
    /// - The key is read once, by the first call that needs it, and kept in memory (`LocalRouterKeyCache`); `route key`
    ///   announces a change, and the next call reads it again, so a change counts from the next request without a
    ///   restart. Without a saved key, nothing is passed on, whatever the route; `routeNeedingKey` then names the route
    ///   that asked for one, so the answer can say why. A key that can't be read (the Keychain won't hand it over
    ///   without asking) isn't kept: it is said once per run of failures, in a line without the key, and keeps requests
    ///   on this Mac.
    /// - Whatever route the file says, the caller then serves a client on another machine `my-macs-first` as `my-macs`
    ///   (`LocalRouterPolicy.route`): a client on the LAN never uses the paid network.
    func effectiveRoute() -> LocalRouterEffectiveRoute {
        // First: without a local key the route doesn't matter, so the file isn't even looked at.
        guard localKeyRequired else { return .thisMacOnly }
        let saved = savedRoute()
        guard saved != .thisMac else { return .thisMacOnly }
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
            return .thisMacOnly
        }
        let route = LocalSettings(route: saved).resolvedRoute(accountKeySaved: true)
        guard let key else {
            // A saved `my-macs` or `my-macs-first` asks for a key. With no route saved, only a key read while this
            // router ran did, and `route key --remove` removed it since.
            let asked = saved != nil || keyCache.keySeenThisRun
            return LocalRouterEffectiveRoute(route: .thisMac, routeNeedingKey: asked ? route : nil)
        }
        guard route != .thisMac else { return .thisMacOnly }
        return LocalRouterEffectiveRoute(route: route, accountKey: key)
    }
}

/// Where a request this Mac can't take goes now (`LocalRouterConfig.effectiveRoute`).
struct LocalRouterEffectiveRoute: Sendable {
    /// The route in effect; `.thisMac` whenever nothing may leave this Mac.
    var route: LocalSettings.Route
    /// The account key `route` passes requests on with; nil with `.thisMac`.
    var accountKey: String?
    /// The route that would pass the request on, but no account key is saved: a saved `my-macs` or `my-macs-first`,
    /// or, with no route saved, `my-macs` once a key read while this router ran was removed. nil otherwise.
    var routeNeedingKey: LocalSettings.Route?

    static let thisMacOnly = LocalRouterEffectiveRoute(route: .thisMac)
}

/// `[local] route` as the provider config file says it now, for a running router: the one place that decides when the
/// file is read again.
///
/// - Each call compares the file with the one it last saw: one `stat`, for its device, inode, size and modification
///   time. Only a change reads it again: `darkbloom route <choice>`'s atomic replace (a new inode each time), or an
///   edit in place (a new size or modification time). On a file system with coarser times than APFS's nanoseconds, an
///   edit in place that keeps the size within the same tick is seen only at the file's next change.
/// - The `stat` comes before the read, so an edit that lands between them is read again by the next call, never
///   missed. The lock is held across the read: one change is read once, and the calls that need the route meanwhile
///   wait for it.
/// - A file that doesn't read as a provider config (a malformed edit, or a file that is gone) keeps the last good
///   route, said once in the log until it reads again. A file missing at the first call isn't read: the route stays as
///   the router started with.
/// - Only a whole file counts (`route(inWhole:stamped:)`). An editor that saves in place empties the file, then writes
///   it, so a read can find it empty, or holding only its start, which can parse without `[local] route`: "no route",
///   which with a key is `my-macs`. Either keeps the last good route like a malformed edit, so a saved `this-mac`
///   never passes a request on while the file is saved.
/// - A line names the file and a route (one of its fixed names) only, never text from the file: the file can hold
///   credentials.
final class LocalRouterRouteFile: @unchecked Sendable {
    private let lock = NSLock()
    /// The file as the last call found it; nil before the first call and while the file is missing.
    private var stamp: Stamp?
    /// The route of the last good read; nil before one (the router's own route counts), `.some(nil)` for a good file
    /// without `[local] route`.
    private var lastGood: LocalSettings.Route??
    /// A bad read was said; the next good one clears it.
    private var failing = false
    private var checkCount = 0

    /// How many times the file was compared (one `stat` each).
    var checks: Int { lock.withLock { checkCount } }

    /// The route the file says now: `initial` (the router's own) until a good read, and the last good one after a bad
    /// read. `read` hands back the file's bytes.
    func route(in file: URL, startingWith initial: LocalSettings.Route?, log: (String) -> Void,
               read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> LocalSettings.Route? {
        lock.withLock {
            checkCount += 1
            let now = Stamp(file)
            let current = lastGood ?? initial
            guard now != stamp else { return current }
            stamp = now
            let outcome = Result { try Self.route(inWhole: read(file), stamped: now) }
            guard case .success(let route) = outcome else {
                // The last good route stands. The error isn't said: it can quote the file.
                if !failing {
                    failing = true
                    log("\(file.lastPathComponent) doesn't read as a provider config now; requests keep the route "
                        + "\(Self.name(current)) until it does")
                }
                return current
            }
            failing = false
            lastGood = .some(route)
            if route != current { log("route is now \(Self.name(route)) (\(file.lastPathComponent) changed)") }
            return route
        }
    }

    static func name(_ route: LocalSettings.Route?) -> String { route?.rawValue ?? "not set" }

    /// `[local] route` in `bytes`, which must be the whole file as `stamp` saw it: not empty, the size the `stat` gave,
    /// and a provider config. Anything less is a save in place caught half done (or a file that is gone or broken),
    /// and throws.
    static func route(inWhole bytes: Data, stamped stamp: Stamp?) throws -> LocalSettings.Route? {
        guard !bytes.isEmpty, Int64(bytes.count) == stamp?.size, let text = String(data: bytes, encoding: .utf8)
        else { throw NotWhole() }
        return try ConfigManager.parseValidating(text).local?.route
    }

    /// A read that isn't the whole file the `stat` saw.
    struct NotWhole: Error {}

    /// What tells one version of the file from another without reading it.
    struct Stamp: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init?(_ file: URL) {
            var info = stat()
            guard stat(file.path, &info) == 0 else { return nil }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }
}

/// The account key as last read, kept in memory so passed-on requests and model lists don't each read the Keychain.
///
/// The copy is kept only while the store's changes are watched: the store posts a Darwin notification when `route key`
/// saves or removes the key, and this drops the copy on it (`notify_register_dispatch`), so the next request reads the
/// key again. A failed read isn't kept, so the next request tries again; a run of failures is said once. A request kept
/// on this Mac because no key is saved is said once too, until a key is read again.
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
    /// Whether a read found a saved key while this router ran.
    private var sawAKey = false
    /// Whether a request kept on this Mac for want of a key was said since this router started or a key was last read.
    private var missingSaid = false

    deinit { if let watch { notify_cancel(watch) } }

    /// Whether a copy is kept now.
    var keepsACopy: Bool { lock.withLock { copy != nil } }

    /// Whether a read found a saved key while this router ran: with no route saved, that key passed requests on.
    var keySeenThisRun: Bool { lock.withLock { sawAKey } }

    /// Notes a request kept on this Mac for want of a key; true for the first since this router started or a key was
    /// last read, so the log says it once for each time the key goes.
    func missingKeyNoted() -> Bool {
        lock.withLock {
            defer { missingSaid = true }
            return !missingSaid
        }
    }

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
            if key != nil {
                sawAKey = true
                missingSaid = false
            }
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
