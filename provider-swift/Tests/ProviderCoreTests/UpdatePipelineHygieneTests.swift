// Copyright © 2026 Eigen Labs.
//
// T1-09 — update pipeline hygiene: the serving daemon's update checks and
// downloads are bounded (the cross-process lease is taken before any network
// step, and `.shared`'s 7-day resource timeout held it until the next
// restart), the bundle hash streams instead of reading ~170 MB into memory,
// and the synchronous stage/commit steps run off the loop actor.
//
// Live-isolated: a real Network.framework listener that accepts and never
// answers (the stalled-coordinator shape), real URLSessions, real files.

import CryptoKit
import Foundation
import Network
import Testing

@testable import ProviderCore

/// TCP listener on loopback that accepts connections, reads whatever arrives,
/// and never replies — a coordinator that took the connection and stalled.
private final class HangingServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hanging-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: self.queue)
            // Keep reading so the client's request is consumed; never write.
            func drain() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, done, error in
                    if error == nil, !done { drain() }
                }
            }
            drain()
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ReadyOnce(cont)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self { self.port = self.listener.port?.rawValue ?? 0 }
                    once.resume(nil)
                case .failed(let error):
                    once.resume(error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private final class ReadyOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func resume(_ error: Error?) {
            let pending: CheckedContinuation<Void, Error>? = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            if let error { pending?.resume(throwing: error) } else { pending?.resume() }
        }
    }

    func stop() {
        listener.cancel()
        let open: [NWConnection] = lock.withLock { connections }
        open.forEach { $0.cancel() }
    }
}

private func tempInstallRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("update-hygiene-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Update pipeline hygiene (T1-09)")
struct UpdatePipelineHygieneTests {

    @Test("the daemon's updater carries the watchdog bounds; the CLI's keeps .shared")
    func daemonUpdaterIsBounded() {
        let daemon = SelfUpdater.forDaemon(coordinatorBaseURL: "https://coordinator.test")
        #expect(daemon.requestTimeoutSeconds == SelfUpdater.watchdogRequestTimeoutSeconds)
        #expect(daemon.resourceTimeoutSeconds == SelfUpdater.watchdogResourceTimeoutSeconds)
        #expect(daemon.verifiesCodeSignatures)

        let cli = SelfUpdater(coordinatorBaseURL: "https://coordinator.test")
        #expect(cli.resourceTimeoutSeconds
            == URLSession.shared.configuration.timeoutIntervalForResource)
    }

    /// A coordinator that accepts the connection and never answers must not
    /// wedge the check (or the lease it holds) — the bounded session turns it
    /// into `.checkFailed` inside its request timeout.
    @Test("a hanging release endpoint fails the check within the request bound")
    func hangingCheckIsBounded() async throws {
        let server = try HangingServer()
        try await server.start()
        defer { server.stop() }
        let root = try tempInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:\(server.port)",
            installRoot: root,
            verifyCodeSignatures: true,
            currentVersion: "0.0.1",
            urlSession: SelfUpdater.boundedURLSession(requestTimeout: 1, resourceTimeout: 3))

        let started = ContinuousClock.now
        let result = await updater.checkForUpdate()
        let elapsed = ContinuousClock.now - started
        guard case .checkFailed = result else {
            Issue.record("expected .checkFailed, got \(result)")
            return
        }
        #expect(elapsed < .seconds(6), "check took \(elapsed); the bound did not apply")
    }

    /// Same for the download: a stalled artifact transfer returns
    /// `.downloadFailed` inside the resource bound instead of holding the
    /// lease for days.
    @Test("a hanging artifact download fails within the resource bound")
    func hangingDownloadIsBounded() async throws {
        let server = try HangingServer()
        try await server.start()
        defer { server.stop() }

        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:\(server.port)",
            urlSession: SelfUpdater.boundedURLSession(requestTimeout: 1, resourceTimeout: 2))
        let release = ReleaseInfo(
            version: "9.9.9", platform: "macos-arm64",
            url: "http://127.0.0.1:\(server.port)/bundle.tar.gz",
            bundleHash: String(repeating: "a", count: 64))

        let started = ContinuousClock.now
        let result = await updater.downloadAndVerify(release: release)
        let elapsed = ContinuousClock.now - started
        guard case .failure(.downloadFailed) = result else {
            Issue.record("expected .downloadFailed, got \(result)")
            return
        }
        #expect(elapsed < .seconds(6), "download took \(elapsed); the bound did not apply")
    }

    @Test("the streamed bundle hash equals the buffered CryptoKit hash")
    func streamedHashMatchesBuffered() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // Larger than any streaming buffer so several chunks are folded.
        var bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024 + 17)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let data = Data(bytes)
        try data.write(to: url)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try SelfUpdater.hexSHA256(ofFileAt: url) == expected)
        #expect(throws: UpdateError.self) {
            try SelfUpdater.hexSHA256(ofFileAt: url.appendingPathExtension("missing"))
        }
    }

    /// The stage/commit steps go through this helper FROM the loop actor:
    /// a blocking step no longer parks the actor, so an actor call issued
    /// during the step is answered at once instead of after the step. The
    /// step is launched through an actor-isolated seam (the same isolation
    /// `stageUpdateBundle`/`commitStagedUpdateBundle` run under); with the
    /// work inlined on the actor the probe call waits the whole second.
    @Test("a blocking update step leaves the loop actor responsive")
    func blockingStepLeavesActorResponsive() async throws {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "update-hygiene-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)

        let stepStarted = Flag()
        let step = Task {
            await loop.runBlockingUpdateStepForTesting { () -> Int in
                stepStarted.set()
                Thread.sleep(forTimeInterval: 1.0)  // tar/codesign/smoke stand-in
                return 42
            }
        }
        // Probe only once the blocking work is actually running.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !stepStarted.value, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(stepStarted.value, "the update step never started")
        let asked = ContinuousClock.now
        _ = await loop.isShuttingDownForTesting()
        let latency = ContinuousClock.now - asked
        #expect(latency < .milliseconds(500), "actor call waited \(latency) behind the update step")
        #expect(await step.value == 42)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
