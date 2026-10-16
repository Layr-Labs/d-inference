import Foundation
import Hummingbird
import NIOCore
@testable import ProviderCore

/// The provider's real local HTTP stack (makeLocalInferenceApplication: disconnect
/// ownership, auth, CORS, upload limits, MLXOpenAIService framing) with the opt-in
/// Super image hook, plus a separate loopback diagnostics listener. Both bind
/// 127.0.0.1 only and require the per-run bearer token.
final class RunnerServer: @unchecked Sendable {
    private let serving: RunnerServing
    private let token: String
    private let log: RunnerEventLog
    private let sampler: RunnerMemorySampler
    private let budget: GlobalKVCacheBudget
    private let tracker = LocalResponseTracker()
    private let admission = RunnerTextAdmission()
    private let ballast = RunnerBallast()
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    init(serving: RunnerServing, token: String, log: RunnerEventLog, sampler: RunnerMemorySampler,
         budget: GlobalKVCacheBudget) {
        self.serving = serving
        self.token = token
        self.log = log
        self.sampler = sampler
        self.budget = budget
    }

    /// Returns (inference port, diagnostics port) once both sockets are bound.
    func start(port: Int, diagnosticsPort: Int, defaultMaxTokens: Int,
               status: @escaping @Sendable () async -> RunnerJSON,
               onFailure: @escaping @Sendable (String) async -> Void) async throws -> (Int, Int) {
        let modelID = NemotronSuperLocalBinding.modelID
        let tokenizer = serving.tokenizer, bridge = serving.bridge, admission = admission
        let inferenceBind = RunnerBind(), diagnosticsBind = RunnerBind()
        let inference = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: UInt16(port), authToken: token),
            defaultMaxTokens: defaultMaxTokens,
            acquire: { requested in
                guard requested == modelID else {
                    throw MultiModelBatchSchedulerEngineError.modelNotLoaded(requested)
                }
                try await admission.acquire()
                return .init(tokenizer: tokenizer,
                    releaseToken: OneShotRelease(release: { _ in await admission.release() }, modelId: modelID),
                    modelType: "nemotron_h_omni", engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [modelID] }, mtpSlots: { [] }, responseTracker: tracker,
            onServerRunning: { channel in await inferenceBind.bound(channel.localAddress?.port) },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: serving.imageHook)
        let diagnostics = Application(router: diagnosticsRouter(status: status),
            configuration: .init(address: .hostname("127.0.0.1", port: diagnosticsPort),
                serverName: "nemotron-super-runner-diagnostics"),
            onServerRunning: { channel in await diagnosticsBind.bound(channel.localAddress?.port) })
        lock.withLock {
            tasks = [
                Self.serve("inference", inference, bind: inferenceBind, onFailure: onFailure),
                Self.serve("diagnostics", diagnostics, bind: diagnosticsBind, onFailure: onFailure),
            ]
        }
        return (try await inferenceBind.port(), try await diagnosticsBind.port())
    }

    private static func serve(_ name: String, _ app: some ApplicationProtocol, bind: RunnerBind,
                              onFailure: @escaping @Sendable (String) async -> Void) -> Task<Void, Never> {
        Task {
            var failure: String?
            do { try await app.runService(gracefulShutdownSignals: []) } catch is CancellationError {
            } catch { failure = "\(name) listener stopped: \(error)" }
            if failure == nil, !Task.isCancelled { failure = "\(name) listener exited" }
            // Settles a waiter that never saw onServerRunning; a no-op once bound.
            await bind.failed(failure ?? "\(name) listener cancelled")
            if let failure { await onFailure(failure) }
        }
    }

    var contextFields: [String: RunnerJSON] {
        get async {
            [
                "http_active_responses": .count(tracker.activeCount),
                "text_acquired": .count(await admission.active),
                "bridge_active_requests": .count(await serving.bridge.activeRequestCount()),
                "ballast_bytes": .bytes(await ballast.bytes),
                "prefix_cache": await RunnerPrefixCache.json(serving.bridge),
            ]
        }
    }

    /// Closes admission, waits for accepted work (bounded), then stops both
    /// listeners. Native retirement is the caller's next step.
    func drain(timeout: Duration) async -> RunnerJSON {
        tracker.setAccepting(false)
        await admission.close()
        let start = ContinuousClock.now
        var timedOut = false
        while true {
            if tracker.activeCount == 0, await admission.active == 0,
               await serving.bridge.activeRequestCount() == 0 { break }
            if ContinuousClock.now - start >= timeout { timedOut = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let fields = await contextFields
        let running = lock.withLock { tasks }
        for task in running { task.cancel() }
        for task in running { await task.value }
        await ballast.releaseAll(budget: budget)
        return RunnerJSON.object(fields).merging([
            "seconds": .seconds(ContinuousClock.now - start), "timed_out": .bool(timedOut),
        ])
    }

    private func diagnosticsRouter(status: @escaping @Sendable () async -> RunnerJSON) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: RunnerBearerAuth(token: token))
        let sampler = sampler, ballast = ballast, budget = budget
        router.get("/runner/status") { _, _ in jsonResponse(await status()) }
        router.get("/runner/memory") { _, _ in jsonResponse(await sampler.snapshot()) }
        router.post("/runner/peaks/reset") { _, _ in jsonResponse(await sampler.resetPeaks()) }
        // Test-only headroom control: a real ledger reservation that shrinks the
        // runtime remainder, for near-limit admission probes. Released at drain.
        router.post("/runner/ballast") { request, _ in
            struct Body: Decodable { let bytes: UInt64 }
            let buffer = try await request.body.collect(upTo: 4096)
            let body = try JSONDecoder().decode(Body.self, from: Data(buffer: buffer))
            return jsonResponse(await ballast.set(body.bytes, budget: budget))
        }
        return router
    }
}

/// Text requests acquire the loaded bridge through this gate, closed at drain.
actor RunnerTextAdmission {
    private var accepting = true
    private(set) var active = 0

    func acquire() throws {
        guard accepting else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded("runner draining")
        }
        active += 1
    }
    func release() { active -= 1 }
    func close() { accepting = false }
}

actor RunnerBallast {
    private(set) var bytes: UInt64 = 0

    func releaseAll(budget: GlobalKVCacheBudget) async {
        await budget.release(requestID: RunnerMemorySampler.ballastID)  // no-op when none is held
        bytes = 0
    }

    func set(_ requested: UInt64, budget: GlobalKVCacheBudget) async -> RunnerJSON {
        if bytes > 0 {
            await budget.release(requestID: RunnerMemorySampler.ballastID)
            bytes = 0
        }
        guard requested > 0 else { return ["accepted": true, "bytes": 0, "requested": 0] }
        let accepted = await budget.reserveBytes(requestID: RunnerMemorySampler.ballastID, bytes: requested)
        if accepted { bytes = requested }
        return ["accepted": .bool(accepted), "bytes": .bytes(bytes), "requested": .bytes(requested)]
    }
}

/// One-shot bind outcome from Hummingbird's onServerRunning callback.
actor RunnerBind {
    private var result: Result<Int, RunnerFailure>?
    private var waiters: [CheckedContinuation<Int, Error>] = []

    func bound(_ port: Int?) {
        settle(port.map { .success($0) } ?? .failure(.serve("bound socket has no port")))
    }
    func failed(_ reason: String) { settle(.failure(.serve(reason))) }

    func port() async throws -> Int {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    private func settle(_ value: Result<Int, RunnerFailure>) {
        guard result == nil else { return }
        result = value
        for waiter in waiters { waiter.resume(with: value.mapError { $0 as Error }) }
        waiters = []
    }
}

struct RunnerBearerAuth<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.headers[.authorization] == "Bearer " + token else {
            return Response(status: .unauthorized)
        }
        return try await next(request, context)
    }
}

private func jsonResponse(_ value: RunnerJSON) -> Response {
    Response(status: .ok, headers: [.contentType: "application/json"],
             body: .init(byteBuffer: ByteBuffer(bytes: value.encoded())))
}
