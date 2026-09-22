import Foundation

public enum SetupAction: Sendable, Equatable {
    case login, doctor, download(String), start(String)
    public var arguments: [String] {
        switch self {
        case .login: ["login"]
        case .doctor: ["doctor"]
        case .download(let id): ["models", "download", id, "--coordinator", "https://api.darkbloom.dev"]
        case .start(let id): ["start", "--model", id, "--coordinator-url", "wss://api.darkbloom.dev/ws/provider"]
        }
    }
}

public enum SetupHandoff {
    /// Commands come only from a closed enum and a fresh coordinator catalog.
    /// An Ollama tag, digest, path, or server response never becomes an argument.
    public static func validate(_ action: SetupAction, catalog: [NetworkModel]) throws {
        switch action {
        case .login, .doctor: return
        case .download(let id), .start(let id):
            guard CatalogPolicy.validID(id), catalog.contains(where: { $0.id == id && $0.active == true }) else { throw ConnectError.invalidModel }
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static func script(action: SetupAction, worker: WorkerIdentity, home: String, coordinatorConfig: URL? = nil) -> String {
        // The terminal handoff is visible and explicit. It does not re-sign,
        // patch or enable proxies in the provider. Recheck identity at launch.
        let binary = quote(worker.executable.path)
        var arguments = action.arguments
        if action == .login, let coordinatorConfig { arguments += ["--config", coordinatorConfig.path] }
        let args = arguments.map(quote).joined(separator: " ")
        return """
        #!/bin/sh
        set -eu
        /usr/bin/codesign --verify --strict -R \(quote(WorkerIdentity.requirement)) \(binary)
        printf '%s\\n' 'Darkbloom Connect: continuing in the signed provider.'
        exec /usr/bin/env -i HOME=\(quote(home)) PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color \(binary) \(args)
        """ + "\n"
    }

    public static func prepare(_ action: SetupAction) async throws -> URL {
        let worker = try WorkerIdentity.inspect()
        switch action {
        case .download, .start:
            let catalog = try CatalogPolicy.decode(await MetadataClient().get(.catalog))
            try validate(action, catalog: catalog)
        case .login, .doctor:
            break // Diagnostics and account linking do not depend on catalog health.
        }
        if case .start = action,
           let s = WorkerSnapshot.read(), let identity = s.process_identity,
           KernelIdentity.read(identity.pid) == identity { throw ConnectError.busy }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darkbloom-connect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("Continue Darkbloom setup.command")
        let config = directory.appendingPathComponent("provider.toml")
        try "[coordinator]\nurl = \"wss://api.darkbloom.dev/ws/provider\"\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        try script(action: action, worker: worker, home: FileManager.default.homeDirectoryForCurrentUser.path, coordinatorConfig: config).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
