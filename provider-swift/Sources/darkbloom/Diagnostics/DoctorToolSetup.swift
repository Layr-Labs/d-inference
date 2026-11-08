import Foundation
import ProviderCore

/// What a tool's own config says of Darkbloom, for `darkbloom doctor`'s Local API section: the file the tool reads
/// (as `darkbloom --opencode` / `--hermes` choose it) and the address and key file of Darkbloom's provider there. Read
/// only; the key itself is never read.
struct DoctorToolSetup: Equatable, Sendable {
    enum Found: Equatable, Sendable {
        /// The tool's config file doesn't exist.
        case noFile
        /// The file has no Darkbloom provider.
        case noEntry
        /// Darkbloom's provider: where it sends requests, and the file it reads the key from.
        case entry(address: String, keyFile: String?)
        /// The file can't be read as the tool's config, and why.
        case unreadable(String)
    }

    let tool: IntegrationTool
    let file: URL
    let found: Found

    /// The tool's name on screen.
    var name: String {
        switch tool {
        case .opencode: "OpenCode"
        case .hermes: "Hermes"
        }
    }

    /// Each tool's config in `environment`, as the tool chooses it.
    static func read(_ environment: ToolIntegrationEnvironment = .current,
                     provider: IntegrationProvider = .current) -> [DoctorToolSetup] {
        IntegrationTool.allCases.map { tool in
            let file = tool.configFile(in: environment)
            guard FileManager.default.fileExists(atPath: file.path) else { return .init(tool: tool, file: file, found: .noFile) }
            guard let data = try? Data(contentsOf: file) else {
                return .init(tool: tool, file: file, found: .unreadable("it can't be read"))
            }
            return .init(tool: tool, file: file, found: found(tool, in: data, provider: provider))
        }
    }

    /// Darkbloom's provider in a config file's bytes.
    static func found(_ tool: IntegrationTool, in data: Data, provider: IntegrationProvider) -> Found {
        switch tool {
        case .opencode: return openCode(data, provider: provider)
        case .hermes:
            do {
                guard let setUp = try HermesConfigPlan.setUp(in: String(decoding: data, as: UTF8.self), provider: provider)
                else { return .noEntry }
                guard let address = setUp.address else { return .unreadable("its \(provider.id) provider has no api address") }
                return .entry(address: address, keyFile: setUp.keyFile)
            } catch {
                return .unreadable(error.reason)
            }
        }
    }

    /// `providers.<id>.settings` in OpenCode's JSONC: `baseURL`, and the file `apiKey`'s `{file:…}` names.
    private static func openCode(_ data: Data, provider: IntegrationProvider) -> Found {
        let document: JSONCDocument
        do {
            document = try JSONCDocument([UInt8](data))
        } catch {
            return .unreadable("it isn't valid JSON (line \(error.line))")
        }
        guard let mine = document.root.object?.members(named: "providers").first?.value.object?
            .members(named: provider.id).first?.value.object else { return .noEntry }
        guard let settings = mine.members(named: "settings").first?.value else {
            return .unreadable("its \(provider.id) provider has no settings")
        }
        struct Settings: Decodable {
            let baseURL: String?
            let apiKey: String?
        }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let written = try? decoder.decode(Settings.self, from: Data(document.bytes[settings.start..<settings.end])),
              let address = written.baseURL else { return .unreadable("its \(provider.id) provider has no baseURL") }
        let keyFile = written.apiKey.flatMap { key -> String? in
            guard key.hasPrefix("{file:"), key.hasSuffix("}") else { return nil }
            return String(key.dropFirst("{file:".count).dropLast())
        }
        return .entry(address: address, keyFile: keyFile)
    }

    /// `path` as a file on this Mac: `~` is `home`.
    static func expanded(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        return path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path
    }

    /// Whether two local API addresses name the same server: the same port and path, and both on this Mac's loopback
    /// (`127.0.0.1`, `localhost`, `::1`), or the same host.
    static func sameAddress(_ one: String, _ other: String) -> Bool {
        guard let first = URLComponents(string: one), let second = URLComponents(string: other) else { return one == other }
        func host(_ url: URLComponents) -> String {
            let name = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return ["127.0.0.1", "localhost", "::1"].contains(name) ? "loopback" : name
        }
        func path(_ url: URLComponents) -> String { url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path }
        return first.scheme?.lowercased() == second.scheme?.lowercased() && host(first) == host(second)
            && first.port == second.port && path(first) == path(second)
    }
}
