import Darwin
import Foundation

/// Process isolation for the qualification runner. Runs before any provider code:
/// home, temp and daemon-state paths point into a fresh state directory, and
/// credential-shaped environment variables are removed (names are logged, never
/// values). The runner constructs no ProviderLoop, coordinator client or config.
struct RunnerIsolation {
    let stateDirectory: URL
    let authToken: String
    let authTokenFile: URL
    let eventsFile: URL
    let readyFile: URL
    let removedEnvironmentKeys: [String]

    private static let credentialMarkers = [
        "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "API_KEY", "APIKEY",
        "PRIVATE_KEY", "AUTH", "SESSION",
    ]
    private static let servicePrefixes = [
        "HF_", "HUGGING", "DARKBLOOM_COORDINATOR", "AWS_", "GH_", "GITHUB_", "OPENAI_",
    ]

    static func prepare(stateDirectory path: String) throws -> RunnerIsolation {
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                try manager.contentsOfDirectory(atPath: directory.path).isEmpty
            else { throw RunnerFailure.isolation("state directory must be new or empty") }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let temporary = directory.appendingPathComponent("tmp", isDirectory: true)
        for child in [home, temporary] {
            try manager.createDirectory(at: child, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let removed = ProcessInfo.processInfo.environment.keys.filter {
            isCredentialShaped($0) || weakensReserve($0)
        }.sorted()
        for key in removed { unsetenv(key) }
        let overrides = [
            "HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": temporary.path + "/",
            "DARKBLOOM_STATE_FILE": directory.appendingPathComponent("daemon-state.json").path,
            "DARKBLOOM_LOADED_MODELS_FILE": directory.appendingPathComponent("loaded-models.json").path,
        ]
        for (key, value) in overrides { setenv(key, value, 1) }

        // A per-run loopback bearer token; not a provider or account credential.
        var generator = SystemRandomNumberGenerator()
        let token = (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
        let tokenFile = directory.appendingPathComponent("auth-token")
        guard manager.createFile(atPath: tokenFile.path, contents: Data(token.utf8),
            attributes: [.posixPermissions: 0o600]) else {
            throw RunnerFailure.isolation("cannot write auth token file")
        }
        return RunnerIsolation(stateDirectory: directory, authToken: token, authTokenFile: tokenFile,
            eventsFile: directory.appendingPathComponent("runner-events.jsonl"),
            readyFile: directory.appendingPathComponent("runner-ready.json"),
            removedEnvironmentKeys: removed)
    }

    /// The cap fraction comes only from the validated --cap-fraction option.
    private static func weakensReserve(_ key: String) -> Bool { key == "DARKBLOOM_MEM_CAP_FRACTION" }

    private static func isCredentialShaped(_ key: String) -> Bool {
        let upper = key.uppercased()
        return credentialMarkers.contains { upper.contains($0) }
            || servicePrefixes.contains { upper.hasPrefix($0) }
    }

    var json: RunnerJSON {
        let environment = ProcessInfo.processInfo.environment
        return [
            "state_dir": .string(stateDirectory.path), "home": .string(environment["HOME"] ?? ""),
            "removed_environment_keys": .array(removedEnvironmentKeys.map { .string($0) }),
            "darkbloom_environment": .object(environment.filter { $0.key.hasPrefix("DARKBLOOM_") }
                .mapValues { .string($0) }),
            "provider_config": "none", "coordinator_connection": "none",
            "discovery_record": "none",
        ]
    }

    /// Atomically publish a ready file only after both loopback listeners bound.
    func writeReady(_ value: RunnerJSON) throws { try publish(value, at: readyFile) }

    func writePreflight(_ value: RunnerJSON) throws {
        try publish(value, at: stateDirectory.appendingPathComponent("runner-preflight.json"))
    }

    private func publish(_ value: RunnerJSON, at url: URL) throws {
        let staging = url.appendingPathExtension("partial")
        try value.encoded(pretty: true).write(to: staging)
        guard rename(staging.path, url.path) == 0 else {
            throw RunnerFailure.isolation("cannot publish \(url.lastPathComponent) (errno \(errno))")
        }
    }
}
