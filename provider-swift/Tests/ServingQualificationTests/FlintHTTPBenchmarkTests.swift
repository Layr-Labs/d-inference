// Copyright © 2026 Eigen Labs.
import CryptoKit
import Darwin
import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

private final class FlintHTTPBenchmarkBundleAnchor: NSObject {}

/// Run only this suite, from a release build, on an otherwise idle GPU.
/// Required: DARKBLOOM_FLINT_HTTP_BENCHMARK=1, _ROOT, _CONFIG, _RECEIPT
/// (the latter three use the same DARKBLOOM_FLINT_HTTP_BENCHMARK prefix),
/// DARKBLOOM_FLINT_CACHE, DARKBLOOM_FLINT_PORT, DARKBLOOM_FLINT_BACKEND=paged,
/// MLX_ENABLE_TF32=0, DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE=2048,
/// DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1 and DARKBLOOM_PREFIX_CACHE_TEST_ROOT;
/// DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY must not be 1 and prefix reuse must
/// be off. Optional _MEASURED (1...200, default 3) and _WORKLOADS
/// (decode_short,prefill_4k). All paths must be inside the explicit task root.
/// Prefix root and receipt must be fresh. Config must select paged/native/native.
/// Results are single-stream (concurrency 1) HTTP measurements from a release
/// test build, not server capacity or signed-CLI qualification.
@Suite("Flint authenticated paged HTTP benchmark", .serialized)
struct FlintHTTPBenchmarkTests {
    private static let modelID = "RecursiveSI/flint-int4"

    private struct Workload {
        let name: String
        let prompt: String
        let maxTokens: Int
    }

    private static let workloads = [
        Workload(name: "decode_short", prompt: """
            Analyze a fictional library's book reservation system. There are three branches,
            twelve delivery vans, and forty patrons waiting for books. A book can have only
            one active reservation, a patron can hold at most three reservations, transfers
            take one day, and a cancellation must release its reservation exactly once.
            Work through an example with simultaneous reservations, a cancellation during
            transfer, and a delayed delivery. Explain the state transitions, invariants,
            fairness rules, failure recovery, and tests that would catch duplicate allocation.
            Consider the tradeoffs carefully and provide a detailed, organized analysis of
            roughly 700 words. Use only these fictional facts and do not call tools.
            """, maxTokens: 512),
        // About 4.1K rendered tokens: two 2048-token stripes plus a short tail.
        Workload(name: "prefill_4k", prompt: ledgerPrompt(lines: 135), maxTokens: 16),
    ]

    private static func ledgerPrompt(lines: Int) -> String {
        let branches = ["Alder", "Birch", "Cedar"]
        let states = ["reserved", "in transfer", "delivered", "cancelled"]
        let ledger = (0..<lines).map { i in
            "Ledger \(String(format: "%04d", i)): branch \(branches[i % 3]), van \(i % 12 + 1), "
                + "patron \((i * 37) % 40 + 1), title River Atlas volume \(i % 9 + 1), "
                + "status \(states[i % 4]), day \(i % 28 + 1)."
        }
        return "Audit this fictional library reservation ledger. Use only these facts and do not call tools.\n"
            + ledger.joined(separator: "\n")
            + "\nList each patron whose active reservations exceed three, then explain the single most likely duplicate allocation."
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_FLINT_HTTP_BENCHMARK"] == "1"),
        .timeLimit(.minutes(120)))
    func fixedPromptPagedThroughput() async throws {
        #if DEBUG
        throw DiagnosticFailure.releaseBuildRequired
        #else
        let environment = ProcessInfo.processInfo.environment
        let inputs = try Inputs(environment: environment)
        let receipt = try Receipt(url: inputs.receipt)
        defer { receipt.close() }
        let previousModelCache = ModelScanner.configuredCacheDirectory
        let previousCacheSettings = CacheStorage.settings
        var server: StandaloneServer?
        var session: URLSession?
        var createdPrefixRoot = false
        var stage = "setup"
        var completedRequests = 0
        do {
            // Bind the staged source-matched library before any MLX use.
            let resources = try #require(Bundle(for: FlintHTTPBenchmarkBundleAnchor.self).resourceURL)
            let library = resources.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
            let metallib = try #require(hashFile(atPath: library.path), "Stage the source-matched test metallib")
            try #require(bindRuntimeMetallibForMLX(from: library) == metallib && metallibHash() == metallib)
            let hardware = try HardwareDetector.detect()
            let ssdPolicy = PrefixCachePolicy.isEnabled(modelId: Self.modelID, environment: environment)
            let residentPolicy = PrefixCachePolicy.isMemoryEnabled(environment: environment)
            try receipt.append(Header(ssdPrefixCachePolicyEnabled: ssdPolicy,
                residentPrefixCachePolicyEnabled: residentPolicy, metallibSHA256: metallib,
                chip: hardware.chipName, gpuCores: Int(hardware.gpuCores),
                measuredRequestsPerWorkload: inputs.measured,
                workloads: inputs.workloads.map { workload in
                    .init(name: workload.name, maxTokens: workload.maxTokens,
                        promptSHA256: Self.digest(Data(workload.prompt.utf8)))
                }))
            // Identical measured prompts must be cold prefills, never prefix hits.
            try #require(!ssdPolicy && !residentPolicy, "Prefix reuse must be disabled for cold measurements")
            let config = try ConfigManager.load(from: inputs.config)
            let backend = config.backend
            let configuredCache = try #require(try ConfigManager.modelCacheDirectory(
                in: config, relativeTo: inputs.config), "Owned config must select its model cache")
            try #require(URL(fileURLWithPath: configuredCache).resolvingSymlinksInPath().standardizedFileURL
                == inputs.modelCache, "Config and explicit task model cache must agree")
            try #require((backend.engineV2KVBackendByModel[Self.modelID] ?? backend.engineV2KVBackend) == "paged")
            try #require((backend.engineV2KVQuantizationByModel[Self.modelID] ?? backend.engineV2KVQuantization) == "native")
            try #require((backend.engineV2KVCheckpointQuantizationByModel[Self.modelID]
                ?? backend.engineV2KVCheckpointQuantization) == "native")
            try #require(backend.mtpDrafterPath == nil, "This Flint benchmark must not import an external drafter")

            // A fresh private root prevents this run's ephemeral key from scanning/deleting another run's files.
            guard mkdir(inputs.prefixRoot.path, 0o700) == 0 else { throw DiagnosticFailure.freshCacheRootRequired }
            createdPrefixRoot = true
            let volume = try CacheVolume.inspect(directory: inputs.prefixRoot.path)
            try CacheStorage.configure(.init(directory: volume.directory, volumeUUID: volume.uuid,
                dailyWriteGB: config.cache.dailyWriteGB))
            ModelScanner.configureCacheDirectory(inputs.modelCache.path)
            let modelDirectory = try #require(ModelScanner.resolveLocalPath(modelID: Self.modelID))
            try Inputs.requireFilesInside(modelDirectory, root: inputs.root)
            let model = try #require(ModelScanner.parseModelInfo(snapshotDir: modelDirectory, modelName: Self.modelID))
            try #require(model.modelType == "flint" && model.templateRenderOK == true)
            try Task.checkCancellation()

            let capabilities = ProviderRuntimeCapabilityDetector.detectLive(hardware: hardware)
            let token = UUID().uuidString + UUID().uuidString
            let ownedServer = StandaloneServer(config: .init(
                port: inputs.port, host: "127.0.0.1", maxCachedModels: Int(clamping: backend.maxModelSlots),
                authToken: token, runtimeCapabilities: capabilities,
                engineV2MaxConcurrent: backend.engineV2MaxConcurrentIsExplicit ? backend.engineV2MaxConcurrent : nil,
                engineV2MaxConcurrentByModel: backend.engineV2MaxConcurrentByModel,
                engineV2KVBackend: backend.engineV2KVBackend,
                engineV2KVBackendByModel: backend.engineV2KVBackendByModel,
                engineV2KVQuantization: backend.engineV2KVQuantization,
                engineV2KVQuantizationByModel: backend.engineV2KVQuantizationByModel,
                engineV2KVCheckpointQuantization: backend.engineV2KVCheckpointQuantization,
                engineV2KVCheckpointQuantizationByModel: backend.engineV2KVCheckpointQuantizationByModel,
                prefillDeadlineMode: backend.prefillDeadlineMode, mtpMode: backend.mtpMode,
                mtpDrafterPath: backend.mtpDrafterPath, mtpAcceptance: backend.mtpAcceptance,
                mtpAcceptanceByModel: backend.mtpAcceptanceByModel,
                coordinatorURL: "http://127.0.0.1:1"), models: [model])
            server = ownedServer
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 900
            configuration.timeoutIntervalForResource = 900
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let ownedSession = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
            session = ownedSession
            let url = try #require(URL(string: "http://127.0.0.1:\(inputs.port)/v1/chat/completions"))
            func request(_ workload: Workload) throws -> URLRequest {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": Self.modelID, "messages": [["role": "user", "content": workload.prompt]],
                    "temperature": 0, "seed": 1,
                    "max_tokens": workload.maxTokens, "stream": true, "stream_options": ["include_usage": true],
                ], options: [.sortedKeys])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                return request
            }
            stage = "bind"
            try await ownedServer.start()
            try #require(await ownedServer.waitUntilBound(timeoutSeconds: 10), "Our listener must own the port")
            stage = "authentication"
            var unauthorized = try request(inputs.workloads[0])
            for authorization in [nil, "Bearer intentionally-invalid"] as [String?] {
                unauthorized.setValue(authorization, forHTTPHeaderField: "Authorization")
                let (bytes, response) = try await ownedSession.bytes(for: unauthorized)
                try #require((response as? HTTPURLResponse)?.statusCode == 401)
                var count = 0
                for try await _ in bytes {
                    count += 1
                    try #require(count <= 65_536, "Unauthorized response exceeded its diagnostic bound")
                }
                try #require(await ownedServer.slots.isEmpty, "Unauthorized requests must not load a model")
                try #require(await ownedServer.modelsLoading.isEmpty, "Unauthorized requests must not start a load")
            }
            for workload in inputs.workloads {
                var authorized = try request(workload)
                authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                var promptTokens: Int?
                var measuredOutputs = Set<String>()
                var measuredCompletionTokens = Set<Int>()
                for iteration in 0...inputs.measured {
                    stage = "\(workload.name)_" + (iteration == 0 ? "warmup" : "measured_\(iteration)")
                    try Task.checkCancellation()
                    let sample = try await Self.measure(authorized, session: ownedSession,
                        workload: workload, iteration: iteration)
                    try await Self.waitUntilIdle(ownedServer)
                    let slot = try await Self.slotEvidence(ownedServer)
                    try #require(slot.backend == "paged" && slot.kvPrecision == "native"
                        && slot.checkpointPrecision == "native", "Resolved production slot must be paged/native/native")
                    try #require(slot.runtime?.soloPrefillStripeTokens == 2048,
                        "The production slot must resolve the 2048-token prefill stripe")
                    try #require((sample.cachedPromptTokens ?? 0) == 0, "Measured prefill must be cold")
                    if let promptTokens { try #require(sample.promptTokens == promptTokens) }
                    promptTokens = sample.promptTokens
                    if sample.measured {
                        measuredOutputs.insert(sample.taggedTextDeltasSHA256)
                        measuredCompletionTokens.insert(sample.completionTokens)
                    }
                    try receipt.append(SampleRecord(sample: sample, slot: slot))
                    completedRequests += 1
                }
                let runtime = try await Self.slotEvidence(ownedServer).runtime
                try receipt.append(WorkloadSummary(workload: workload.name,
                    promptTokens: promptTokens ?? 0,
                    stripeExercised: (promptTokens ?? 0) > (runtime?.prefillChunkSize ?? .max),
                    identicalMeasuredOutputs: measuredOutputs.count == 1 && measuredCompletionTokens.count == 1))
            }
            stage = "shutdown"
            ownedSession.invalidateAndCancel()
            await Self.shutdown(ownedServer)
            try #require(await ownedServer.slots.isEmpty)
            try #require(ownedServer.responseTracker.activeCount == 0)
            stage = "restore_globals"
            ModelScanner.configureCacheDirectory(previousModelCache)
            try CacheStorage.configure(previousCacheSettings)
            try FileManager.default.removeItem(at: inputs.prefixRoot)
            try Task.checkCancellation()
            try receipt.append(Completion(status: "complete", stage: "finished",
                completedRequests: completedRequests, cleanupComplete: true, errorType: nil))
        } catch {
            session?.invalidateAndCancel()
            if let server { await Self.shutdown(server) }
            ModelScanner.configureCacheDirectory(previousModelCache)
            var cleanupComplete = true
            do { try CacheStorage.configure(previousCacheSettings) }
            catch { cleanupComplete = false; Issue.record("Could not restore prior cache settings") }
            if let server {
                let empty = await server.slots.isEmpty
                cleanupComplete = cleanupComplete && empty && server.responseTracker.activeCount == 0
            }
            if createdPrefixRoot, FileManager.default.fileExists(atPath: inputs.prefixRoot.path) {
                do { try FileManager.default.removeItem(at: inputs.prefixRoot) }
                catch { cleanupComplete = false }
            }
            do {
                try receipt.append(Completion(status: "failed", stage: stage,
                    completedRequests: completedRequests, cleanupComplete: cleanupComplete,
                    errorType: String(reflecting: type(of: error))))
            } catch { Issue.record("Could not finish the benchmark receipt") }
            throw error
        }
        #endif
    }

    private static func shutdown(_ server: StandaloneServer) async {
        // Drain in a non-cancelled task even when the test's HTTP consumer was cancelled.
        await Task.detached { await server.stopAndWait() }.value
    }

    private static func waitUntilIdle(_ server: StandaloneServer) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let active = await server.debugActiveRequestCount(modelId: modelID)
            let reserved = await server.debugSlotReservationCount(modelId: modelID)
            if active == 0 && reserved == 0 && server.responseTracker.activeCount == 0 { return }
            try #require(ContinuousClock.now < deadline, "Completed HTTP request did not drain")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func slotEvidence(_ server: StandaloneServer) async throws -> SlotEvidence {
        // Return only scalar metadata; never retain a slot/container past server shutdown.
        let bridge = try #require(await server.slots[modelID]?.bridge)
        let defaults = await bridge.samplingDefaults
        let backend = await bridge.kvBackendKind
        let artifactSHA256 = await server.slots[modelID]?.modelArtifactSHA256
        return SlotEvidence(backend: backend.rawValue,
            kvPrecision: bridge.kvQuantization.rawValue, checkpointPrecision: bridge.kvCheckpointQuantization.rawValue,
            artifactSHA256: artifactSHA256, prefixCache: bridge.prefixCacheModelStatus(),
            runtime: bridge.deadlineRuntimeConfiguration, temperature: defaults.temperature ?? 0,
            topP: defaults.topP ?? 1, topK: defaults.topK ?? 0, repetitionPenalty: defaults.repetitionPenalty ?? 1)
    }

    private static func measure(_ request: URLRequest, session: URLSession, workload: Workload,
        iteration: Int) async throws -> Sample {
        let start = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        let http = try #require(response as? HTTPURLResponse)
        guard http.statusCode == 200 else { throw DiagnosticFailure.httpStatus(http.statusCode) }
        try #require(http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true)
        var capture = SSECapture()
        var line = Data()
        var event = Data()
        var totalBytes = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            guard totalBytes <= 8 * 1024 * 1024 else { throw DiagnosticFailure.streamLimit }
            if byte != 10 {
                line.append(byte)
                guard line.count <= 256 * 1024 else { throw DiagnosticFailure.streamLimit }
                continue
            }
            if line.last == 13 { line.removeLast() }
            if line.isEmpty {
                if !event.isEmpty {
                    try capture.consume(event, seconds: seconds(start.duration(to: ContinuousClock.now)))
                    event.removeAll(keepingCapacity: true)
                }
            } else if line.starts(with: Data("data:".utf8)) {
                var payload = line.dropFirst(5)
                if payload.first == 32 { payload = payload.dropFirst() }
                if !event.isEmpty { event.append(10) }
                event.append(contentsOf: payload)
                guard event.count <= 256 * 1024 else { throw DiagnosticFailure.streamLimit }
            }
            line.removeAll(keepingCapacity: true)
            if capture.doneSeconds != nil { break }
        }
        return try capture.sample(workload: workload, iteration: iteration)
    }

    private struct SSECapture {
        var firstDeltaSeconds: Double?
        var firstDeltaKind: String?
        var doneSeconds: Double?
        var finishReason: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedPromptTokens: Int?
        var usageCount = 0
        var textHash = SHA256()

        mutating func consume(_ event: Data, seconds: Double) throws {
            if event == Data("[DONE]".utf8) { doneSeconds = seconds; return }
            guard let json = try JSONSerialization.jsonObject(with: event) as? [String: Any], json["error"] == nil
            else { throw DiagnosticFailure.streamProtocol }
            if let usage = json["usage"] as? [String: Any] {
                usageCount += 1
                promptTokens = usage["prompt_tokens"] as? Int
                completionTokens = usage["completion_tokens"] as? Int
                cachedPromptTokens = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
            }
            let choices = json["choices"] as? [[String: Any]] ?? []
            guard choices.count <= 1 else { throw DiagnosticFailure.streamProtocol }
            for choice in choices {
                if let finish = choice["finish_reason"] as? String {
                    guard finishReason == nil, ["stop", "length", "tool_calls", "content_filter"].contains(finish)
                    else { throw DiagnosticFailure.streamProtocol }
                    finishReason = finish
                }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                note(delta["reasoning_content"] as? String, kind: "reasoning", seconds: seconds)
                note(delta["content"] as? String, kind: "content", seconds: seconds)
                for tool in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = tool["function"] as? [String: Any] ?? [:]
                    note(function["name"] as? String, kind: "tool_name", seconds: seconds)
                    note(function["arguments"] as? String, kind: "tool_arguments", seconds: seconds)
                }
            }
        }

        mutating func note(_ text: String?, kind: String, seconds: Double) {
            guard let text, !text.isEmpty else { return }
            if firstDeltaSeconds == nil { firstDeltaSeconds = seconds; firstDeltaKind = kind }
            // Hash the ordered, field-tagged text deltas; never retain output or token IDs.
            let data = Data(text.utf8)
            textHash.update(data: Data("\(kind):\(data.count):".utf8))
            textHash.update(data: data)
        }

        func sample(workload: Workload, iteration: Int) throws -> Sample {
            guard let elapsed = doneSeconds, let first = firstDeltaSeconds, elapsed > first,
                let finishReason, let firstDeltaKind, usageCount == 1,
                let promptTokens, promptTokens > 0, let completionTokens,
                (1...workload.maxTokens).contains(completionTokens)
            else { throw DiagnosticFailure.incompleteStream }
            return Sample(workload: workload.name, iteration: iteration, measured: iteration > 0, httpStatus: 200,
                promptTokens: promptTokens, completionTokens: completionTokens, cachedPromptTokens: cachedPromptTokens,
                finishReason: finishReason, firstDeltaKind: firstDeltaKind, ttftSeconds: first,
                secondsToDone: elapsed, endToEndTokensPerSecond: Double(completionTokens) / elapsed,
                // The first delta already carries at least one generated token.
                postFirstDeltaTokensPerSecondEstimate: Double(completionTokens - 1) / (elapsed - first),
                promptTokensPerTTFTSecond: Double(promptTokens) / first,
                taggedTextDeltasSHA256: textHash.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    private struct Inputs {
        let root: URL
        let config: URL
        let modelCache: URL
        let prefixRoot: URL
        let receipt: URL
        let port: UInt16
        let measured: Int
        let workloads: [Workload]

        init(environment: [String: String]) throws {
            func absolute(_ key: String) throws -> URL {
                guard let path = environment[key], path.hasPrefix("/"), !path.utf8.contains(0)
                else { throw DiagnosticFailure.requiredEnvironment(key) }
                // Production reads these raw spellings; refuse any that resolve elsewhere.
                let raw = URL(fileURLWithPath: path).standardizedFileURL
                let resolved = raw.resolvingSymlinksInPath().standardizedFileURL
                guard raw.path == resolved.path else { throw DiagnosticFailure.requiredEnvironment(key) }
                return resolved
            }
            root = try absolute("DARKBLOOM_FLINT_HTTP_BENCHMARK_ROOT")
            try #require(root.pathComponents.count > 3 && root != FileManager.default.homeDirectoryForCurrentUser)
            config = try absolute("DARKBLOOM_FLINT_HTTP_BENCHMARK_CONFIG")
            modelCache = try absolute("DARKBLOOM_FLINT_CACHE")
            prefixRoot = try absolute("DARKBLOOM_PREFIX_CACHE_TEST_ROOT")
            receipt = try absolute("DARKBLOOM_FLINT_HTTP_BENCHMARK_RECEIPT")
            for path in [config, modelCache, prefixRoot, receipt] {
                try #require(Self.contains(path, in: root), "Every diagnostic path must be inside the declared task root")
            }
            try #require(!Self.contains(prefixRoot, in: modelCache) && prefixRoot != modelCache)
            try #require(!Self.contains(receipt, in: modelCache) && !Self.contains(receipt, in: prefixRoot))
            try #require(environment["DARKBLOOM_FLINT_BACKEND"] == "paged")
            try #require(environment["MLX_ENABLE_TF32"] == "0", "TF32 must be explicitly disabled")
            try #require(environment[EngineV2Factory.soloPrefillStripeKey] == "2048")
            try #require(environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"] == "1")
            try #require(environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] != "1")
            guard let rawPort = environment["DARKBLOOM_FLINT_PORT"], let value = UInt16(rawPort), value > 1024
            else { throw DiagnosticFailure.requiredEnvironment("DARKBLOOM_FLINT_PORT") }
            port = value
            let measuredKey = "DARKBLOOM_FLINT_HTTP_BENCHMARK_MEASURED"
            guard let measured = Int(environment[measuredKey] ?? "3"), (1...200).contains(measured)
            else { throw DiagnosticFailure.requiredEnvironment(measuredKey) }
            self.measured = measured
            let workloadsKey = "DARKBLOOM_FLINT_HTTP_BENCHMARK_WORKLOADS"
            let names = (environment[workloadsKey] ?? "decode_short,prefill_4k").split(separator: ",").map(String.init)
            let selected = names.compactMap { name in FlintHTTPBenchmarkTests.workloads.first { $0.name == name } }
            guard !selected.isEmpty, selected.count == names.count, Set(names).count == names.count
            else { throw DiagnosticFailure.requiredEnvironment(workloadsKey) }
            workloads = selected
        }

        static func contains(_ child: URL, in parent: URL) -> Bool {
            child.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/")
        }

        /// Snapshot entries can be per-file links; every loaded file must resolve inside the task root.
        static func requireFilesInside(_ directory: URL, root: URL) throws {
            try #require(contains(directory.resolvingSymlinksInPath(), in: root))
            let entries = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for entry in entries {
                try #require(contains(entry.resolvingSymlinksInPath(), in: root),
                    "Model files must resolve inside the declared task root")
            }
        }
    }

    private final class Receipt {
        private let handle: FileHandle
        init(url: URL) throws {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DiagnosticFailure.freshReceiptRequired }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        func append<T: Encodable>(_ value: T) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try handle.write(contentsOf: encoder.encode(value) + Data([10]))
            try handle.synchronize()
        }
        func close() { try? handle.close() }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private struct Header: Encodable {
        struct WorkloadIdentity: Encodable {
            let name: String
            let maxTokens: Int
            let promptSHA256: String
        }
        let event = "started"
        let schemaVersion = 2
        let providerVersion = ProviderCore.version
        let modelID = FlintHTTPBenchmarkTests.modelID
        let buildConfiguration = "release test build (@testable), not the signed CLI"
        let tf32 = "disabled (MLX_ENABLE_TF32=0 required)"
        let promptMode = "fixed_synthetic"
        let warmupRequestsPerWorkload = 1
        let concurrentHTTPRequests = 1
        let configuredSoloPrefillStripeTokens = 2048
        let stripeValidation = "exact environment and the production slot's resolved runtime configuration"
        let cacheKeyMode = "isolated_ephemeral_no_restart_persistence"
        let prefixReuse = "disabled; every sample must report zero cached prompt tokens"
        let sampling = "temperature=0, seed=1; remaining fields use production artifact defaults; slot reports artifact defaults separately"
        let rateDefinition = "terminal completion_tokens / request-start-to-DONE seconds"
        let estimateDefinition = "(terminal completion_tokens - 1) / first-nonempty-delta-to-DONE seconds; includes hidden reasoning tokens; NOT GPU decode throughput"
        let prefillDefinition = "prompt_tokens / request-start-to-first-nonempty-delta seconds; includes HTTP, tokenization and first decode step; a lower bound on engine prefill throughput"
        let scope = "single-stream HTTP at concurrency 1; not aggregate server capacity"
        let ssdPrefixCachePolicyEnabled: Bool
        let residentPrefixCachePolicyEnabled: Bool
        let metallibSHA256: String
        let chip: String
        let gpuCores: Int
        let measuredRequestsPerWorkload: Int
        let workloads: [WorkloadIdentity]
    }
    private struct SlotEvidence: Encodable {
        let backend: String
        let kvPrecision: String
        let checkpointPrecision: String
        let artifactSHA256: String?
        let prefixCache: PrefixCacheModelStatus
        let runtime: DeadlineRuntimeConfiguration?
        let temperature: Float
        let topP: Float
        let topK: Int
        let repetitionPenalty: Float
    }
    private struct SampleRecord: Encodable {
        let event = "sample"
        let sample: Sample
        let slot: SlotEvidence
    }
    private struct Sample: Encodable {
        let workload: String
        let iteration: Int
        let measured: Bool
        let httpStatus: Int
        let promptTokens: Int
        let completionTokens: Int
        let cachedPromptTokens: Int?
        let finishReason: String
        let firstDeltaKind: String
        let ttftSeconds: Double
        let secondsToDone: Double
        let endToEndTokensPerSecond: Double
        let postFirstDeltaTokensPerSecondEstimate: Double
        let promptTokensPerTTFTSecond: Double
        let taggedTextDeltasSHA256: String
    }
    private struct WorkloadSummary: Encodable {
        let event = "workload_summary"
        let workload: String
        let promptTokens: Int
        let stripeExercised: Bool
        let identicalMeasuredOutputs: Bool
    }
    private struct Completion: Encodable {
        let event = "completion"
        let status: String
        let stage: String
        let completedRequests: Int
        let cleanupComplete: Bool
        let errorType: String?
    }
    private enum DiagnosticFailure: Error {
        case releaseBuildRequired, freshCacheRootRequired, freshReceiptRequired
        case requiredEnvironment(String), httpStatus(Int), streamLimit, streamProtocol, incompleteStream
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
