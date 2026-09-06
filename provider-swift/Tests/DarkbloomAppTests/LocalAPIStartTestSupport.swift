import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ProviderCoreFoundation
@testable import DarkbloomApp

actor LocalAPIRecordingCLI: LocalAPIProviderRunning {
    struct Invocation: Sendable {
        let arguments: [String]
    }
    private(set) var invocations: [Invocation] = []
    private var pending: CheckedContinuation<ProviderCLIResult, any Error>?

    // Deliberately ignores cancellation until resolve(), exercising late-result
    // fencing without ever creating a Process or touching a real endpoint.
    func run(arguments: [String], onLaunch: @escaping @Sendable (ProcessIdentity) -> Void) async throws -> ProviderCLIResult {
        invocations.append(Invocation(arguments: arguments))
        onLaunch(ProcessIdentity(pid: 9942, startTimeMicros: 200_000))
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func resolve(_ result: Result<ProviderCLIResult, any Error> = .success(.init(exitStatus: 0, stderrTail: ""))) {
        pending?.resume(with: result)
        pending = nil
    }
}

actor LocalAPIProbeGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

final class LocalAPIStartWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var record: LocalEndpointInfo?
    private var identity: ProcessIdentity?
    private var catalog: [String] = []
    private var status = 200
    private var count = 0
    let probeGate: LocalAPIProbeGate?

    init(probeGate: LocalAPIProbeGate? = nil) { self.probeGate = probeGate }
    var info: LocalEndpointInfo? { lock.withLock { record } }
    var probeCount: Int { lock.withLock { count } }
    func readIdentity(_ pid: Int32) -> ProcessIdentity? {
        lock.withLock { identity?.pid == pid ? identity : nil }
    }
    func publish(_ info: LocalEndpointInfo?, models: [String], status: Int = 200) {
        lock.withLock {
            record = info
            identity = info?.processIdentity
            catalog = models
            self.status = status
        }
    }
    func setIdentity(_ next: ProcessIdentity?) { lock.withLock { identity = next } }
    func reusePID() {
        lock.withLock {
            if let old = identity {
                identity = ProcessIdentity(pid: old.pid, startTimeMicros: old.startTimeMicros + 1)
            }
        }
    }
    func client(_ info: LocalEndpointInfo) -> LocalEndpointClient {
        LocalEndpointClient(
            baseURL: URL(string: info.baseURL)!, apiKey: info.apiKey,
            dataTransport: { [self] request in
                let (models, status) = lock.withLock {
                    count += 1
                    return (catalog, self.status)
                }
                if let probeGate { await probeGate.wait() }
                let body = try JSONSerialization.data(withJSONObject: ["data": models.map { ["id": $0] }])
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            },
            lineTransport: { _ in throw LocalEndpointError.unreachable("No streaming in this test") }
        )
    }
}

@MainActor
func localAPIStartStore(
    cli: LocalAPIRecordingCLI,
    world: LocalAPIStartWorld,
    readinessTimeout: Duration = .seconds(2),
    shutdownTimeout: Duration = .seconds(1),
    waitForReadinessTimeout: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    providerConflictReader: @escaping @Sendable () -> LocalAPIStartConflict? = { nil }
) -> LocalAPIStore {
    LocalAPIStore.live(
        discoveryReader: { world.info }, processIdentityReader: { world.readIdentity($0) },
        cli: cli,
        startConfiguration: .init(nonReplacingLaunchVerified: true, readinessTimeout: readinessTimeout, pollInterval: .milliseconds(1), shutdownTimeout: shutdownTimeout, waitForReadinessTimeout: waitForReadinessTimeout),
        providerConflictReader: providerConflictReader,
        clientFactory: { world.client($0) }
    )
}

func localAPIInstalledModel(id: String = "test/installed-model") -> ModelSummary {
    ModelSummary(
        id: id, displayName: "Installed test model", family: nil, kind: .text,
        summary: "", sizeBytes: 1_000, minimumMemoryGB: nil, quantization: nil,
        maxContextLength: nil, capabilities: [.textGeneration], origin: .localOnly,
        fit: .fits, installation: .installed, runtime: .cold
    )
}

func localAPIStartInfo(pid: Int32 = 9942) -> LocalEndpointInfo {
    LocalEndpointInfo(
        host: "127.0.0.1", port: 8000, apiKey: "test-only-token", version: "0.8.5",
        pid: pid, processIdentity: ProcessIdentity(pid: pid, startTimeMicros: 200_000),
        updatedAt: "2026-09-05T12:00:00Z"
    )
}

@MainActor
func localAPIEventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

@MainActor
func requestLocalAPIStart(_ store: LocalAPIStore, model: ModelSummary = localAPIInstalledModel()) {
    store.startLocalOnly(
        modelID: model.id, models: [model], modelsAreLive: true,
        providerSnapshot: ProviderPreviewScenario.paused.snapshot
    )
}
