import Foundation

/// Where a tool set up for Darkbloom sends its requests, as its config says now: the base URL of Darkbloom's provider
/// block and the file its key comes from; nil for what the block doesn't say in the form Darkbloom writes.
struct ToolPointer: Equatable, Sendable {
    var baseURL: String?
    var keyFile: URL?
}

/// After a start without `--opencode` / `--hermes`, the tools set up for Darkbloom that point elsewhere than this
/// Mac's local API, said in one line that names the command that points them at it again. Read only: such a start never
/// changes a tool's config; only that command does.
enum ToolAddress {
    /// How a tool's provider block misses the local API.
    enum Miss: Equatable, Sendable {
        /// It sends requests to another base URL.
        case address(String)
        /// It reads the key from another file (its path), one that doesn't hold the local API's key.
        case key(String)
    }

    /// Darkbloom's provider block in `tool`'s config, as it points now; nil when the tool isn't set up for Darkbloom
    /// (no config, or no block in it) or its config can't be read.
    static func pointer(of tool: IntegrationTool, environment: ToolIntegrationEnvironment,
                        provider: IntegrationProvider) -> ToolPointer? {
        guard let bytes = try? Data(contentsOf: tool.configFile(in: environment), options: .mappedIfSafe),
              bytes.count <= ToolConfigWriter.maximumFileBytes else { return nil }
        switch tool {
        case .opencode: return OpenCodeConfigPlan.pointer(in: bytes, provider: provider, home: environment.home)
        case .hermes: return HermesConfigPlan.pointer(in: bytes, provider: provider)
        }
    }

    /// The names loopback answers to, as every local API on this Mac does.
    static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// The names a tool on this Mac reaches its local API listening on `bind` by: loopback's, and this Mac's Bonjour
    /// name (`localHostName`, with `.local`) when it listens on every address, as `darkbloom local` prints it then.
    static func thisMacsNames(listeningOn bind: String, localHostName: () -> String?) -> Set<String> {
        guard bind == "0.0.0.0" || bind == "::", let name = localHostName() else { return loopbackNames }
        return loopbackNames.union(["\(name.lowercased()).local"])
    }

    /// Whether two base URLs reach the same local API: the same scheme, port (the scheme's own when none is given) and
    /// path (one `/` at its end aside), and the same host in any case, `thisMac`'s names counting as one.
    static func sameAddress(_ one: String, _ other: String, thisMac: Set<String> = loopbackNames) -> Bool {
        guard let first = URLComponents(string: one), let second = URLComponents(string: other),
              first.host != nil, second.host != nil else { return trimmed(one) == trimmed(other) }
        func scheme(_ url: URLComponents) -> String? { url.scheme?.lowercased() }
        func host(_ url: URLComponents) -> String {
            let name = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return thisMac.contains(name) ? "this Mac" : name
        }
        func port(_ url: URLComponents) -> Int? {
            url.port ?? ["http": 80, "https": 443][scheme(url) ?? ""]
        }
        return scheme(first) == scheme(second) && host(first) == host(second) && port(first) == port(second)
            && trimmed(first.path) == trimmed(second.path)
    }

    /// The tools set up for Darkbloom whose provider block misses the local API at `baseURL` that takes the key in
    /// `keyFile` (nil: the API takes no key, so any file does), and how. `thisMac`: the names it answers to.
    static func misses(baseURL: String, keyFile: URL?, environment: ToolIntegrationEnvironment,
                       provider: IntegrationProvider,
                       thisMac: Set<String> = loopbackNames) -> [(tool: IntegrationTool, miss: Miss)] {
        IntegrationTool.allCases.compactMap { tool in
            guard let pointer = pointer(of: tool, environment: environment, provider: provider) else { return nil }
            if let url = pointer.baseURL, !sameAddress(url, baseURL, thisMac: thisMac) { return (tool, .address(url)) }
            if let keyFile, let theirs = pointer.keyFile, !sameKey(theirs, keyFile) {
                return (tool, .key(theirs.standardizedFileURL.path))
            }
            return nil
        }
    }

    /// The one line for `misses`, or nil when there are none: what the tools point at, and the command that points
    /// them at the local API again.
    static func notice(_ misses: [(tool: IntegrationTool, miss: Miss)], baseURL: String, keyFile: URL?,
                       home: URL) -> String? {
        guard let first = misses.first?.miss else { return nil }
        let tools = misses.map(\.tool)
        let one = tools.count == 1
        let names = ToolIntegrationStep.names(tools)
        let fix = "`\(ToolIntegrationStep.command(tools))` points \(one ? "it" : "them") there."
        // Tools that miss it in different ways share one line that names no address or file.
        guard misses.allSatisfy({ $0.miss == first }) else {
            return "\(names) \(one ? "doesn't" : "don't") point at this Mac's local API (\(baseURL)): \(fix)"
        }
        switch first {
        case .address(let url):
            return "\(names) \(one ? "points" : "point") at \(url), not this Mac's local API (\(baseURL)): \(fix)"
        case .key(let path):
            let theirs = ToolIntegration.displayPath(URL(fileURLWithPath: path), home: home)
            let ours = keyFile.map { " (\(ToolIntegration.displayPath($0, home: home)))" } ?? ""
            return "\(names) \(one ? "reads" : "read") the key in \(theirs), not the one this Mac's local API "
                + "takes\(ours): \(fix)"
        }
    }

    /// The line for a start that serves its local API at `baseURL`, with the key in `keyFile` (nil: no key).
    /// `thisMac`: the names the API answers to.
    static func notice(baseURL: String, keyFile: URL?, environment: ToolIntegrationEnvironment = .current,
                       provider: IntegrationProvider = .current, thisMac: Set<String> = loopbackNames) -> String? {
        notice(misses(baseURL: baseURL, keyFile: keyFile, environment: environment, provider: provider,
                      thisMac: thisMac),
               baseURL: baseURL, keyFile: keyFile, home: environment.home)
    }

    private static func trimmed(_ url: String) -> String { url.hasSuffix("/") ? String(url.dropLast()) : url }

    /// The same file, or two files that hold the same key.
    private static func sameKey(_ one: URL, _ other: URL) -> Bool {
        if one.standardizedFileURL.path == other.standardizedFileURL.path { return true }
        func key(_ file: URL) -> String? {
            (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let ours = key(other), !ours.isEmpty else { return false }
        return key(one) == ours
    }
}
