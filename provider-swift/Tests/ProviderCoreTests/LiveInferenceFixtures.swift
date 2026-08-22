import Foundation
import MLX
import MLXLLM
import Testing
import MLXLMCommon
@testable import ProviderCore

// MARK: - Tiny, fast model used for the bulk of live tests.

enum LiveInferenceFixtures {
    /// Default tiny MLX-community model: ~600M params, ~1 GB on disk in 8-bit.
    /// Loads in seconds and finishes a 16-token generation in well under 1s
    /// on Apple Silicon. Has a chat template; no tool-calling weirdness.
    static let tinyModelID = "mlx-community/Qwen3-0.6B-8bit"

    /// Backup tiny model used in the chat-template fidelity test if the
    /// preferred Qwen3 tiny is missing locally.
    static let tinyModelFallbackID = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    /// Large MoE Gemma model. Gated additionally by DARKBLOOM_LIVE_MLX_GEMMA=1
    /// so CI runners (and small dev machines) don't pay the 27 GB load cost
    /// every test run.
    static let gemmaModelID = "mlx-community/gemma-4-26b-a4b-it-8bit"

    /// Env var that opts a process into running live MLX tests.
    static let liveEnvVar = "DARKBLOOM_LIVE_MLX_TESTS"

    /// Additional env var required for the multi-GB Gemma test.
    static let gemmaEnvVar = "DARKBLOOM_LIVE_MLX_GEMMA"

    /// Additional env var required for tests that need two distinct local models.
    static let multiModelEnvVar = "DARKBLOOM_LIVE_MLX_MULTI_MODEL"

    // MARK: Gating

    /// Interprets an operator gate consistently across live, probe, hardware,
    /// and release-gate suites. Empty values and explicit false spellings are
    /// disabled; every other non-empty value opts in.
    static func gateValueEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return !["0", "false", "no", "off"].contains(normalized)
    }

    static func gateEnabled(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        gateValueEnabled(environment[name])
    }

    /// True when the operator opted into running live tests.
    static var liveTestsEnabled: Bool {
        gateEnabled(liveEnvVar)
    }

    /// True when the operator opted into Gemma. Implies `liveTestsEnabled`.
    static var gemmaTestsEnabled: Bool {
        liveTestsEnabled && gateEnabled(gemmaEnvVar)
    }

    /// True when the operator opted into tests that require two small local models.
    static var multiModelLiveTestsEnabled: Bool {
        liveTestsEnabled && gateEnabled(multiModelEnvVar)
    }

    /// Records an ordinary test failure when an opted-in lane is missing a
    /// runtime prerequisite. Callers retain control of cleanup and early return.
    static func recordUnavailable(_ reason: String) {
        Issue.record("required lane prerequisite unavailable: \(reason)")
    }

    // MARK: Model location

    /// Result of trying to find the local snapshot for a model id.
    enum ModelLocation {
        /// The model is on disk at `directory`.
        case found(URL)
        /// The model id was not present in the local HF cache.
        case missing(String)
    }

    /// Resolve a model id to its local snapshot dir, or return `.missing`.
    /// Live tests use this to skip cleanly when a model isn't downloaded.
    static func locate(_ modelID: String) -> ModelLocation {
        if let url = ModelScanner.resolveLocalPath(modelID: modelID) {
            return .found(url)
        }
        return .missing(modelID)
    }

    // MARK: Metallib bootstrap

    /// MLX (the C++ runtime) looks for `mlx.metallib` next to the binary
    /// containing the `mlx::core::current_binary_dir` symbol. Cmlx is linked
    /// statically into the xctest test bundle, so that resolves to the test
    /// bundle's main executable directory:
    ///
    ///   `.build/<arch>/debug/<pkg>PackageTests.xctest/Contents/MacOS/`
    ///
    /// The canonical source helper stages a metallib in the Swift build
    /// directory. This helper finds that source and always replaces the copy
    /// beside the test runner so a stale pre-existing file cannot survive into
    /// the current test invocation.
    ///
    /// Returns the path to the colocated metallib on success, or `nil` if no
    /// source metallib could be found -- in which case the caller should skip
    /// the test rather than crashing in GPU initialization.
    static func ensureMetallibColocated() -> URL? {
        MLXMetallibEnvironment.withExclusiveAccess {
            let fm = FileManager.default

            // 1. Find the test bundle's MacOS dir. Bundle(for:) reliably points
            //    at the .xctest bundle even when launched via the system
            //    `xctest` host (where _NSGetExecutablePath returns the host).
            guard let testBundleMacOSDir = testBundleExecutableDir() else {
                return nil
            }
            let destination = testBundleMacOSDir.appendingPathComponent("mlx.metallib")

            // 2. Resolve the authoritative staged source before considering the
            // runner copy. Existence alone does not prove source compatibility.
            guard let source = findSourceMetallib() else {
                return nil
            }

            do {
                // Copy beside the destination, then atomically replace the runner
                // file without loading the 150 MB+ metallib into process memory.
                let temporary = testBundleMacOSDir
                    .appendingPathComponent(".mlx.metallib.\(UUID().uuidString)")
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: source, to: temporary)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try fm.moveItem(at: temporary, to: destination)
                }
                // Mirror to MLX_METALLIB_PATH so our own `locateMetallib()`
                // (which trusts _NSGetExecutablePath, i.e. the xctest host
                // path) can find it too if anyone else queries.
                MLXMetallibEnvironment.setPath(destination.path)
                return destination
            } catch {
                // The C++ runtime does not honor MLX_METALLIB_PATH, so failure to
                // replace its runner-local copy must remain a fixture failure.
                MLXMetallibEnvironment.setPath(source.path)
                return nil
            }
        }
    }

    /// Resolve the directory containing the test runner's main executable.
    /// Uses `Bundle(for:)` on a sentinel class so we get the *test bundle*
    /// (`.xctest`) path, not the xctest host's path that
    /// `_NSGetExecutablePath` would return when running under
    /// `swift test` / `xctest`.
    private static func testBundleExecutableDir() -> URL? {
        let bundle = Bundle(for: BundleSentinel.self)
        if let exec = bundle.executableURL {
            return exec.deletingLastPathComponent()
        }
        // Fallback: `<bundle>/Contents/MacOS`. Bundle.bundleURL on macOS
        // points at the .xctest directory itself.
        let macOSDir = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
        if FileManager.default.fileExists(atPath: macOSDir.path) {
            return macOSDir
        }
        return nil
    }

    /// Look for a metallib at the canonical helper's drop sites. We anchor at
    /// the test bundle (`.build/<arch>/<configuration>/...`) and accept only
    /// the configuration which contains the running test bundle.
    private static func findSourceMetallib() -> URL? {
        let fm = FileManager.default

        // Anchor at the test bundle path -- much more reliable than
        // _NSGetExecutablePath under `swift test`.
        let bundle = Bundle(for: BundleSentinel.self)
        let components = bundle.bundleURL.pathComponents
        let configuration: String
        if let buildIndex = components.lastIndex(of: ".build"),
           let activeConfiguration = components[components.index(after: buildIndex)...]
            .first(where: { $0 == "debug" || $0 == "release" }) {
            configuration = activeConfiguration
        } else {
            configuration = "debug"
        }

        var cursor = bundle.bundleURL
        for _ in 0..<12 {
            if cursor.lastPathComponent == ".build" {
                let candidates: [URL] = [
                    cursor.appendingPathComponent("\(configuration)/mlx.metallib"),
                    cursor.appendingPathComponent(
                        "arm64-apple-macosx/\(configuration)/mlx.metallib"
                    ),
                ]
                for candidate in candidates {
                    if fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
                break
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        return nil
    }

    // MARK: Memory budget

    /// Cap MLX cache memory for the test process so a misbehaving test
    /// doesn't gobble all of unified RAM and starve the rest of the suite.
    /// Idempotent. Uses the same default budget as `ProviderLoop` for parity.
    static func applyMemoryBudget(maxBytes: Int = 12 * 1024 * 1024 * 1024) {
        // The deprecated `GPU.set(...)` aliases are kept for now because the
        // newer `MLX.Memory.{cacheLimit,memoryLimit}` setters route through
        // the same C function and produce a deprecation warning either way
        // pending an mlx-swift bump. memoryLimit is a soft target on
        // active+cache.
        MLX.GPU.set(cacheLimit: maxBytes)
        MLX.GPU.set(memoryLimit: maxBytes)
    }

    // MARK: Loading

    /// Everything `loadBridge` returns: the PRODUCTION v2 bridge (built
    /// through `EngineV2SlotFactory.makeProductionBridge` — the one-engine
    /// construction every serving slot uses), the retained container, the
    /// checkpoint directory, and the sizing snapshot. Caller is responsible
    /// for `await bridge.shutdown()` + `MLX.Memory.clearCache()` when
    /// finished (use `defer` in the test).
    struct LoadedBridge {
        let bridge: EngineV2Bridge
        let container: ModelContainer
        let modelDirectory: URL
        let sizing: SlotSizingSnapshot
    }

    /// Load a model and build its production v2 bridge, including direct use
    /// of a VLM wrapper's owned text tower.
    ///
    /// - Throws: `LiveFixtureSkip` if the model isn't on disk, or if the
    ///   metallib isn't available.
    static func loadBridge(
        modelID: String,
        modelType: String? = nil,
        maxConcurrentRequests: Int = 4,
        memoryBudgetBytes: Int? = nil,
        defaultMaxTokens: Int = 256,
        kvBackendConfig: String = "auto"
    ) async throws -> LoadedBridge {
        guard ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }

        let directory: URL
        switch locate(modelID) {
        case .found(let url):
            directory = url
        case .missing(let id):
            throw LiveFixtureSkip.modelNotInCache(id)
        }

        applyMemoryBudget(maxBytes: memoryBudgetBytes ?? 12 * 1024 * 1024 * 1024)

        let container = try await ModelContainerLoading.loadContainer(from: directory)
        var sizing = try await SlotSizingSnapshot.build(
            container: container,
            modelPath: directory,
            fallbackDefaultMaxTokens: defaultMaxTokens)
        if sizing.defaultMaxTokens > defaultMaxTokens {
            sizing = SlotSizingSnapshot(
                weightsBytes: sizing.weightsBytes,
                fp16KVBytesPerToken: sizing.fp16KVBytesPerToken,
                maxContextLength: sizing.maxContextLength,
                defaultMaxTokens: defaultMaxTokens)
        }
        // Single-slot grant: the full fleet budget for this model's weights
        // (the same figure a lone serving slot is granted).
        let grant = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        let isVLM = ProviderLoop.modelIsVLM(at: directory)
        let bridge = try await EngineV2SlotFactory.makeProductionBridge(
            modelId: modelID,
            modelType: modelType ?? modelTypeFromConfig(directory: directory),
            isVLM: isVLM,
            modelDirectory: directory,
            container: container,
            tokenizer: await container.perform { ctx in TokenizerHandle(ctx.tokenizer) },
            sizing: sizing,
            kvBytesCapacity: grant,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBudget: nil,
            kvBackendConfig: kvBackendConfig,
            // Hermetic tests: master-kill EVERY prefix-cache tier. An empty
            // environment is no longer dormant — the SSD tier (v0.7.5) is
            // default-on and would write real files under the user's
            // ~/Library/Caches/darkbloom/kv3. Dedicated suites opt in with
            // their own roots/keys.
            environment: ["DARKBLOOM_PREFIX_CACHE": "0"])

        return LoadedBridge(
            bridge: bridge, container: container, modelDirectory: directory, sizing: sizing)
    }

    /// `model_type` from the checkpoint's config.json (nil when absent).
    static func modelTypeFromConfig(directory: URL) -> String? {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["model_type"] as? String
    }
}

// MARK: - Bundle anchoring

/// Sentinel class used as a `Bundle(for:)` anchor to locate the test
/// runner's `.xctest` bundle. Must be a `class` (not a `struct`) -- only
/// classes have an associated bundle.
private final class BundleSentinel {}

// MARK: - Skip plumbing

/// Errors thrown by fixtures when the runtime environment can't satisfy
/// a precondition. Tests catch these and surface them as a recorded
/// "skipped" issue with the reason.
enum LiveFixtureSkip: Error, CustomStringConvertible {
    case modelNotInCache(String)
    case missingMetallib

    var description: String {
        switch self {
        case .modelNotInCache(let id):
            return """
                model '\(id)' is not in the local HuggingFace cache. Run \
                `huggingface-cli download \(id)` (or set HF_HOME) and retry.
                """
        case .missingMetallib:
            return """
                mlx.metallib not found anywhere under .build/. Run \
                `./scripts/fetch-metallib.sh debug` from the repo root \
                (the test fixture copies it next to the xctest runner).
                """
        }
    }
}

// MARK: - Generation collection

/// Collect events from `EngineV2Bridge.submitTokenized(...)` into a
/// structured result so test assertions can be expressed simply.
struct CollectedGeneration {
    var chunks: [String] = []
    var info: (promptTokens: Int, completionTokens: Int, tokensPerSecond: Double)?
    var error: String?

    var fullText: String { chunks.joined() }
    var didError: Bool { error != nil }
    var didFinish: Bool { info != nil || error != nil }
}

/// Submit pre-tokenized prompt tokens to a v2 bridge and collect the full
/// event stream into a structured result. (Chat templating lives with the
/// caller — exactly like the production request path, where
/// `MultiModelBatchSchedulerEngine` templates before `submitTokenized`.)
///
/// Implemented as a free function (not an actor extension) so the bridge
/// is not held while we iterate.
func collect(
    from bridge: EngineV2Bridge,
    promptTokens: [Int],
    request: ChatCompletionRequest,
    requestId: String? = nil
) async -> CollectedGeneration {
    let stream = await bridge.submitTokenized(
        promptTokens: promptTokens, request: request, requestId: requestId)
    var collected = CollectedGeneration()
    for await event in stream {
        switch event {
        case .chunk(let text):
            collected.chunks.append(text)
        case .info(let prompt, let completion, let tps, _):
            collected.info = (prompt, completion, tps)
        case .error(let message):
            collected.error = message
        case .terminal(_, let message, _, _):
            // A typed platform/engine terminal is an error terminal for this
            // generic collector — record its (cause-prefixed) message.
            collected.error = message
        }
    }
    return collected
}

@Suite("Provider test lane gate parsing")
struct ProviderTestLaneGateTests {
    @Test(
        "empty and explicit false values stay disabled",
        arguments: ["", "0", "false", "FALSE", " no ", "off"])
    func explicitFalseValues(rawValue: String) {
        #expect(!LiveInferenceFixtures.gateValueEnabled(rawValue))
    }

    @Test(
        "other non-empty values opt in",
        arguments: ["1", "true", "yes", "on", "enabled"])
    func optInValues(rawValue: String) {
        #expect(LiveInferenceFixtures.gateValueEnabled(rawValue))
    }

    @Test("hardware lane is disabled by default and opts in explicitly")
    func hardwareLaneGate() {
        let name = "DARKBLOOM_HARDWARE_TESTS"
        #expect(!LiveInferenceFixtures.gateEnabled(name, environment: [:]))
        #expect(!LiveInferenceFixtures.gateEnabled(name, environment: [name: "false"]))
        #expect(LiveInferenceFixtures.gateEnabled(name, environment: [name: "1"]))
    }
}
