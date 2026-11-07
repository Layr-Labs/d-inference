import ArgumentParser
import Foundation
import NIOCore
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

/// `darkbloom route`: where the owner's requests go when this Mac can't take them (the local router).
struct Route: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "route",
        abstract: "Where your requests go when this Mac can't take them.",
        discussion: """
        This Mac's local API answers your requests first. With an account API key saved, a request this Mac can't \
        take goes on to your other Macs (free), and with `[local] route = "my-macs-first"` then to the Darkbloom \
        network (billed). Without a key, requests stay on this Mac.
        """,
        subcommands: [RouteKey.self]
    )
}

/// `darkbloom route key [--stdin | --remove]`: saves the account API key in this Mac's Keychain, or removes it.
struct RouteKey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Save your account API key for the local router, or remove it.",
        discussion: """
        Create a key in the Darkbloom console; a self-route-only key is the safe choice unless you want the network \
        to answer when your Macs can't. The key goes into this Mac's Keychain only: it is never printed, logged, or \
        written to provider.toml, local.json or any tool's config. It is checked once with Darkbloom before it is saved.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(help: "Read the key from standard input (one line) instead of asking for it with hidden input.")
    var stdin = false

    @Flag(help: "Remove the saved key: your requests then stay on this Mac.")
    var remove = false

    func validate() throws {
        if stdin && remove { throw ValidationError("--stdin and --remove can't be used together.") }
    }

    func run() async throws {
        Darkbloom.ensureLogging()
        let loaded = try? loadRuntimeConfiguration(configPath: configOptions.config)
        let upstream = LocalRouterPolicy.upstreamBaseURL(coordinatorURL: loaded?.config.coordinator.url)
        let flow = RouteKeyFlow(
            store: KeychainLocalRouterAccountKeyStore(),
            savedRoute: loaded?.config.local?.route,
            check: { key in await RouteKeyFlow.checkWithDarkbloom(key: key, upstream: upstream) },
            say: { print($0) })
        if remove {
            throw ExitCode(flow.remove())
        }
        let key: String
        if stdin {
            key = RouteKeyFlow.firstLine(of: FileHandle.standardInput.readDataToEndOfFile())
        } else {
            guard let typed = RouteKeyFlow.readHidden(prompt: "Account API key (input hidden): ") else {
                printError("No terminal to ask in: pipe the key in with `\(BuildEnvironment.current.cliName) route key --stdin`.")
                throw ExitCode.failure
            }
            key = typed
        }
        throw ExitCode(await flow.save(key))
    }
}

/// What checking a key with Darkbloom found.
enum RouteKeyCheck: Equatable, Sendable {
    /// Darkbloom took it; `models` of the owner's Macs' models are live now.
    case accepted(models: Int)
    /// Darkbloom refused it (401 or 403), with its message.
    case refused(String)
    /// Darkbloom could not be asked now.
    case unchecked(String)
}

/// The steps of `route key`, apart from the terminal and the Keychain. Nothing it says contains the key.
struct RouteKeyFlow {
    let store: any LocalRouterAccountKeyStore
    let savedRoute: LocalSettings.Route?
    let check: @Sendable (String) async -> RouteKeyCheck
    let say: (String) -> Void
    var liveEndpointHasNoLocalKey = false

    func save(_ rawKey: String) async -> Int32 {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refusal = LocalRouterAccountKeyFormat.refusal(key) {
            say("✗ Not saved: \(refusal).")
            return 1
        }
        let note: String
        switch await check(key) {
        case .refused(let message):
            say("✗ Darkbloom refused this key (\(message)). Nothing was saved.")
            return 1
        case .accepted(let models):
            note = "Darkbloom accepted it; your Macs serve " + (models == 1 ? "1 model" : "\(models) models") + " now."
        case .unchecked(let reason):
            note = "It couldn't be checked with Darkbloom now (\(reason))."
        }
        do {
            try store.save(key)
        } catch {
            say("✗ Not saved: \(error).")
            return 1
        }
        say("✓ Account key saved in this Mac's Keychain. " + note)
        for line in Self.routeLines(savedRoute: savedRoute, keySaved: true) { say(line) }
        say("A running local API uses it from its next request that needs it; no restart is needed.")
        return 0
    }

    func remove() -> Int32 {
        do {
            try store.remove()
        } catch {
            say("✗ The key could not be removed: \(error).")
            return 1
        }
        say("✓ Account key removed from this Mac's Keychain.")
        for line in Self.routeLines(savedRoute: savedRoute, keySaved: false) { say(line) }
        return 0
    }

    /// Where requests go with this route and key, in the iPhone app's words. Never a speed.
    static func routeLines(savedRoute: LocalSettings.Route?, keySaved: Bool) -> [String] {
        let route = LocalSettings(route: savedRoute).resolvedRoute(accountKeySaved: keySaved)
        switch (route, keySaved) {
        case (.thisMac, true):
            return ["Your requests: this Mac only ([local] route = \"this-mac\"). The key is used once you choose your Macs."]
        case (_, false):
            return ["Your requests: this Mac only, until an account key is saved again."]
        case (.myMacs, true):
            return ["Your requests: this Mac first, then your other Macs (free)."]
        case (.myMacsFirst, true):
            return ["Your requests: this Mac first, then your other Macs (free), then the Darkbloom network (billed to "
                        + "your balance; the network needs a positive balance).",
                    "With a self-route-only key, Darkbloom answers only from your Macs, even with My Macs first."]
        }
    }

    /// `GET /v1/models` with the key and `X-Darkbloom-Route: self`: the owner's live models.
    static func checkWithDarkbloom(key: String, upstream: URL,
                                   transport: any LocalRouterTransport = URLSessionLocalRouterTransport()) async
        -> RouteKeyCheck {
        let request = LocalRouterUpstreamRequest(
            url: URL(string: upstream.absoluteString + "/v1/models") ?? upstream, method: "GET",
            headers: ["Authorization": "Bearer " + key, LocalRouterPolicy.routeHeader.rawName: "self",
                      "Accept": "application/json", "Accept-Encoding": "identity"],
            body: nil, connectTimeout: .seconds(10), idleTimeout: .seconds(10))
        let response: LocalRouterUpstreamResponse
        do {
            response = try await transport.send(request)
        } catch {
            return .unchecked((error as? LocalRouterUpstreamError)?.description ?? "Darkbloom could not be reached")
        }
        var body = Data()
        do {
            for try await chunk in response.body where body.count < 4 * 1024 * 1024 { body.append(contentsOf: chunk.readableBytesView) }
        } catch {
            return .unchecked("Darkbloom's answer was cut off")
        }
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        switch response.status {
        case 200:
            return .accepted(models: (object?["data"] as? [Any])?.count ?? 0)
        case 401, 403:
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            return .refused((message ?? "HTTP \(response.status)").replacingOccurrences(of: key, with: "[key]"))
        default:
            return .unchecked("Darkbloom answered HTTP \(response.status)")
        }
    }

    static func firstLine(of data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return String(text.split(whereSeparator: \.isNewline).first ?? "")
    }

    /// One line typed at the terminal without echo; nil without a terminal.
    static func readHidden(prompt: String) -> String? {
        let tty = open("/dev/tty", O_RDWR)
        guard tty >= 0 else { return nil }
        defer { close(tty) }
        var saved = termios()
        guard tcgetattr(tty, &saved) == 0 else { return nil }
        var silent = saved
        silent.c_lflag &= ~tcflag_t(ECHO)
        _ = prompt.withCString { write(tty, $0, strlen($0)) }
        guard tcsetattr(tty, TCSAFLUSH, &silent) == 0 else { return nil }
        defer {
            tcsetattr(tty, TCSAFLUSH, &saved)
            _ = "\n".withCString { write(tty, $0, 1) }
        }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(tty, &byte, 1) == 1, byte != UInt8(ascii: "\n"), byte != UInt8(ascii: "\r") {
            bytes.append(byte)
            if bytes.count > LocalRouterAccountKeyFormat.maximumLength * 2 { break }
        }
        defer { bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        return String(decoding: bytes, as: UTF8.self)
    }
}
