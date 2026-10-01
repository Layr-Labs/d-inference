import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

@testable import darkbloom

/// A temporary provider home for one exit-test child process.
///
/// `enter()` changes process-wide environment variables and registers a
/// URL protocol on the shared URL session. Call it only inside the body of
/// an exit test: that body runs in its own child process, so the change
/// never reaches the parent test process or other tests.
///
/// Every file the commands under test read or write is in `root`: the
/// daemon state file, the auth token, the KV-backend guard, the watchdog
/// state, the provider config and the model cache. The coordinator is the
/// in-process stub `CoordinatorStub`, so no request leaves the process.
struct CLICommandSandbox {
    static let coordinatorURL = "https://coordinator.invalid"

    let root: URL
    let cache: URL
    let config: URL
    let stateFile: URL
    let tokenFile: URL
    let guardFile: URL
    let watchdogStateFile: URL

    static func enter(
        enabledModels: [String] = [],
        autoUpdate: Bool = true
    ) throws -> CLICommandSandbox {
        let sandbox = try CLICommandSandbox()
        setenv("DARKBLOOM_STATE_FILE", sandbox.stateFile.path, 1)
        setenv("DARKBLOOM_AUTH_TOKEN_PATH", sandbox.tokenFile.path, 1)
        setenv(KVBackendGuardStore.pathEnvKey, sandbox.guardFile.path, 1)
        setenv("DARKBLOOM_WATCHDOG_STATE", sandbox.watchdogStateFile.path, 1)
        setenv("DARKBLOOM_NO_UPDATE_CHECK", "1", 1)
        setenv("NO_COLOR", "1", 1)
        unsetenv("SUDO_USER")
        CoordinatorStub.install([:])
        try sandbox.writeConfig(enabledModels: enabledModels, autoUpdate: autoUpdate)
        return sandbox
    }

    private init() throws {
        // Use the canonical path so /var and /private/var aliases do not
        // hide which cache a command selected.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("cli-sandbox-\(UUID().uuidString)", isDirectory: true)
        cache = root.appendingPathComponent("hub", isDirectory: true)
        config = root.appendingPathComponent("provider.toml")
        stateFile = root.appendingPathComponent("state/daemon-state.json")
        tokenFile = root.appendingPathComponent("state/auth_token")
        guardFile = root.appendingPathComponent("state/kv-backend-guard.json")
        watchdogStateFile = root.appendingPathComponent("state/watchdog-state.json")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeConfig(enabledModels: [String] = [], autoUpdate: Bool = true) throws {
        let value = ProviderConfig(
            provider: ProviderSettings(name: "cli-sandbox", memoryReserveGB: 1, autoUpdate: autoUpdate),
            backend: BackendSettings(modelCacheDirectory: cache.path, enabledModels: enabledModels),
            coordinator: CoordinatorSettings(url: Self.coordinatorURL, heartbeatIntervalSecs: 5))
        try ConfigManager.save(value, to: config)
    }

    /// A minimal Hugging Face cache entry that the model scanner accepts.
    @discardableResult
    func makeModel(_ id: String) throws -> URL {
        let modelDirectory = cache.appendingPathComponent(
            "models--" + id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        let snapshot = modelDirectory.appendingPathComponent("snapshots/local", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"model_type":"llama"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 64).write(to: snapshot.appendingPathComponent("model.safetensors"))
        return modelDirectory
    }

    func writeToken(_ token: String) throws {
        try Data((token + "\n").utf8).write(to: tokenFile)
    }

    func writeState(_ state: DaemonState) {
        DaemonStateFile.write(state, to: stateFile)
    }

    /// The configuration the commands load, with a fixed hardware profile.
    func snapshot(hardware: HardwareInfo?) throws -> RuntimeSnapshot {
        RuntimeSnapshot(
            configPath: config,
            configFileExists: true,
            config: try ConfigManager.load(from: config),
            hardware: hardware,
            hardwareError: nil,
            models: [],
            configuredModelCacheDirectory: cache.path)
    }

    static let hardware = HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)

    /// Daemon state that belongs to the current process, so the CLI treats
    /// it as a running provider.
    static func runningState(
        now: Double,
        writtenAt: Double? = nil,
        trust: DaemonState.Trust? = nil,
        attestationPublicKey: String? = nil,
        currentModel: String? = nil,
        warmModels: [String] = [],
        advertisedModels: [String]? = nil,
        stats: DaemonState.Stats = DaemonState.Stats(),
        capacity: DaemonState.Capacity? = nil,
        lastModelLoadError: DaemonState.ModelLoadError? = nil
    ) throws -> DaemonState {
        guard let identity = ProcessIdentity.current() else {
            throw CocoaError(.featureUnsupported)
        }
        return DaemonState(
            pid: identity.pid,
            processIdentity: identity,
            version: ProviderCore.version,
            writtenAt: writtenAt ?? now,
            startedAt: now - 3_700,
            attestationPublicKey: attestationPublicKey,
            trust: trust,
            coordinatorURL: coordinatorURL,
            currentModel: currentModel,
            warmModels: warmModels,
            advertisedModels: advertisedModels,
            stats: stats,
            capacity: capacity,
            lastModelLoadError: lastModelLoadError)
    }

    /// A current App Attest authorization for this sandbox's coordinator.
    static func appAttestAuthorization(now: Double, removalReady: Bool = false) -> ProviderAuthorizationStatus {
        ProviderAuthorizationStatus(
            appAttestAvailable: true, path: "app_attest", expiresAt: now + 600,
            mdmRemovalReady: removalReady, sessionID: "session-1", machineID: "machine-1")
    }

    static func releaseJSON(
        version: String, binaryHash: String? = nil, metallibHash: String? = nil
    ) -> Data {
        var object: [String: Any] = [
            "version": version,
            "platform": "macos-arm64",
            "url": "https://downloads.invalid/darkbloom-\(version).tar.gz",
            "bundle_hash": "bundle-\(version)",
        ]
        if let binaryHash { object["binary_hash"] = binaryHash }
        if let metallibHash { object["metallib_hash"] = metallibHash }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

enum CLICommandSandboxError: Error {
    case unexpectedCommand(String)
}

/// Parses `arguments` from the root command, checks the command type and runs it.
func runCLICommand<Command: AsyncParsableCommand>(
    _ type: Command.Type, _ arguments: [String]
) async throws {
    guard var command = try Darkbloom.parseAsRoot(arguments) as? Command else {
        throw CLICommandSandboxError.unexpectedCommand(arguments.joined(separator: " "))
    }
    try await command.run()
}

/// Runs a command that must fail with `ExitCode.failure`, and returns the
/// error it threw. Returns nil when it did not throw.
func runFailingCLICommand<Command: AsyncParsableCommand>(
    _ type: Command.Type, _ arguments: [String]
) async throws -> (any Error)? {
    guard var command = try Darkbloom.parseAsRoot(arguments) as? Command else {
        throw CLICommandSandboxError.unexpectedCommand(arguments.joined(separator: " "))
    }
    do {
        try await command.run()
        return nil
    } catch {
        return error
    }
}

/// Replaces standard input with `text`, for commands that read a confirmation.
func replaceStandardInput(with text: String) throws {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    try pipe.fileHandleForWriting.close()
    guard dup2(pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO) >= 0 else {
        throw POSIXError(.EBADF)
    }
    clearerr(stdin)
}

func decodedText(_ bytes: [UInt8]) -> String {
    String(decoding: bytes, as: UTF8.self)
}

/// Answers every request on the shared URL session from a fixed table keyed
/// by URL path. A path without an entry gets HTTP 404. Requests are kept so
/// a test can check what the command sent.
final class CoordinatorStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data

        static func json(_ status: Int, _ text: String) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var registered = false

    static func install(_ table: [String: Reply]) {
        let register = lock.withLock { () -> Bool in
            replies = table
            recorded = []
            defer { registered = true }
            return !registered
        }
        if register {
            _ = URLProtocol.registerClass(CoordinatorStub.self)
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let reply = Self.lock.withLock { () -> Reply in
            Self.recorded.append(request)
            return Self.replies[request.url?.path ?? ""] ?? Reply(status: 404, body: Data())
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": "\(reply.body.count)",
                ])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
