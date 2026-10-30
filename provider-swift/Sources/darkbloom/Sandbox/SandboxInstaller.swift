import Foundation
import ProviderCore

/// The owner's choices for `darkbloom sandbox setup` that reach the installer.
struct SandboxSetupOptions: Equatable, Sendable {
    var server = Sandbox.defaultServer
    var noBrowser = false
    var waitReady = false
    var linuxSlots: Int?
    var macOSSlots: Int?
}

/// Downloads the add-on's installer (`install.sh`) from the Darkbloom
/// Sandbox service and prepares its run. The installer itself verifies the
/// release (publisher signature, archive digest, Developer ID team) before it
/// installs anything; this side only insists on HTTPS end to end.
enum SandboxInstaller {
    static let maximumScriptBytes = 1 << 20
    static let downloadTimeout: TimeInterval = 30
    /// Installers that render their stages for the CLI accept this option and
    /// name it in their text; older ones reject unknown options.
    static let jsonProgressOption = "--json-progress"
    /// Installers from add-on 1.1.1 on accept this option and name it in their
    /// text: they check this Mac and print the add-on's slot plan, installing
    /// nothing. An installer is run with it only when its text names it.
    static let planOption = "--plan"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case download(URL, String)

        var description: String {
            switch self {
            case .download(let url, let reason):
                return "Could not download the Darkbloom Sandbox installer from \(url.absoluteString): \(reason)."
            }
        }
    }

    /// `<server>/install.sh`. Only an https URL with a host and no query,
    /// fragment or credentials is accepted.
    static func scriptURL(server: String) -> URL? {
        guard var components = URLComponents(string: server), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/install.sh"
        return components.url
    }

    /// Reads at most one byte past `maximumScriptBytes`, so a larger body is
    /// refused without being held in memory.
    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: downloadTimeout)
        request.setValue("\(BuildEnvironment.current.cliName)/\(ProviderCore.version)", forHTTPHeaderField: "User-Agent")
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, received) = try await URLSession.shared.bytes(for: request, delegate: HTTPSRedirectsOnly())
            response = received
            // Another status is refused below without its body.
            if (received as? HTTPURLResponse)?.statusCode == 200 {
                guard received.expectedContentLength <= maximumScriptBytes else {
                    throw Failure.download(url, "the response is too large")
                }
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maximumScriptBytes { break }
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(url, error.localizedDescription)
        }
        return try validate(data, response: response, from: url)
    }

    /// A 200 over HTTPS (after any redirects) carrying a shell script of at
    /// most `maximumScriptBytes`.
    static func validate(_ data: Data, response: URLResponse, from url: URL) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw Failure.download(url, "no HTTP response") }
        if (300..<400).contains(http.statusCode) {
            throw Failure.download(url, "it redirected to a location that is not https")
        }
        guard http.statusCode == 200 else { throw Failure.download(url, "HTTP \(http.statusCode)") }
        guard http.url?.scheme?.lowercased() == "https" else {
            throw Failure.download(url, "the response did not come over https")
        }
        guard data.count <= maximumScriptBytes else { throw Failure.download(url, "the response is too large") }
        let firstLine = String(decoding: data.prefix(256).prefix { $0 != 0x0A }, as: UTF8.self)
        guard firstLine.hasPrefix("#!"), firstLine.contains("sh") else {
            throw Failure.download(url, "the response is not a shell script")
        }
        return data
    }

    static func supportsJSONProgress(_ script: Data) -> Bool {
        String(decoding: script, as: UTF8.self).contains(jsonProgressOption)
    }

    static func supportsPlan(_ script: Data) -> Bool {
        String(decoding: script, as: UTF8.self).contains(planOption)
    }

    /// The installer's arguments. An installer without `--json-progress`
    /// knows only the slot options, so the others are left out for it.
    static func arguments(_ options: SandboxSetupOptions, jsonProgress: Bool) -> [String] {
        var arguments: [String] = []
        if jsonProgress {
            // setup has asked already, and the installer's stdin is closed.
            arguments += [jsonProgressOption, "--yes"]
            if options.noBrowser { arguments.append("--no-browser") }
            if options.waitReady { arguments.append("--wait-ready") }
        }
        return arguments + slotArguments(options)
    }

    /// The arguments that ask for the add-on's plan for the owner's slot
    /// counts. No `--yes`: the plan installs nothing.
    static func planArguments(_ options: SandboxSetupOptions) -> [String] {
        [planOption, jsonProgressOption] + slotArguments(options)
    }

    private static func slotArguments(_ options: SandboxSetupOptions) -> [String] {
        var arguments: [String] = []
        if let linux = options.linuxSlots { arguments += ["--linux-slots", String(linux)] }
        if let macOS = options.macOSSlots { arguments += ["--macos-slots", String(macOS)] }
        return arguments
    }

    /// Writes the script into a new owner-only directory and returns its path;
    /// the caller removes the directory.
    static func stage(_ script: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-sandbox-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("install.sh")
        guard FileManager.default.createFile(atPath: file.path, contents: script,
                                             attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return file
    }

    /// Follows a redirect only to another https URL.
    private final class HTTPSRedirectsOnly: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme?.lowercased() == "https" ? request : nil
        }
    }
}
