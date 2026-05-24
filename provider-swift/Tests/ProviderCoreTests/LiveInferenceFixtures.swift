import Foundation
import MLX
import MLXLLM
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

    /// True when the operator opted into running live tests.
    static var liveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment[liveEnvVar].map { !$0.isEmpty } ?? false
    }

    /// True when the operator opted into Gemma. Implies `liveTestsEnabled`.
    static var gemmaTestsEnabled: Bool {
        liveTestsEnabled
            && (ProcessInfo.processInfo.environment[gemmaEnvVar].map { !$0.isEmpty } ?? false)
    }

    /// True when the operator opted into tests that require two small local models.
    static var multiModelLiveTestsEnabled: Bool {
        liveTestsEnabled
            && (ProcessInfo.processInfo.environment[multiModelEnvVar].map { !$0.isEmpty } ?? false)
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
    /// `scripts/fetch-metallib.sh` only places the metallib at
    /// `.build/debug/mlx.metallib`, which is *not* where MLX looks. This
    /// helper finds the metallib in any well-known location (incl. the
    /// fetch script's drop site) and copies it next to the test runner
    /// so MLX's `current_binary_dir() / "mlx.metallib"` lookup succeeds
    /// on the first GPU call. Idempotent.
    ///
    /// Returns the path to the colocated metallib on success, or `nil` if
    /// no source metallib could be found anywhere -- in which case the
    /// caller should skip the test rather than crashing in the GPU init.
    static func ensureMetallibColocated() -> URL? {
        let fm = FileManager.default

        // 1. Find the test bundle's MacOS dir. Bundle(for:) reliably points
        //    at the .xctest bundle even when launched via the system
        //    `xctest` host (where _NSGetExecutablePath returns the host).
        guard let testBundleMacOSDir = testBundleExecutableDir() else {
            return nil
        }
        let destination = testBundleMacOSDir.appendingPathComponent("mlx.metallib")

        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        // 2. Find a source metallib to copy.
        guard let source = findSourceMetallib() else {
            return nil
        }

        do {
            try fm.copyItem(at: source, to: destination)
            // Mirror to MLX_METALLIB_PATH so our own `locateMetallib()`
            // (which trusts _NSGetExecutablePath, i.e. the xctest host
            // path) can find it too if anyone else queries.
            setenv("MLX_METALLIB_PATH", destination.path, 1)
            return destination
        } catch {
            // Last resort: still set MLX_METALLIB_PATH so any code that
            // queries `locateMetallib()` succeeds, even though the MLX
            // C++ runtime won't honor it and tests will crash on first
            // GPU call. Better to let the test report the failure than
            // to silently skip.
            setenv("MLX_METALLIB_PATH", source.path, 1)
            return nil
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

    /// Look for a metallib at the spots `scripts/fetch-metallib.sh` and the
    /// release pipeline drop one. We anchor at the test bundle (which is
    /// inside `.build/<arch>/debug/...`) and walk up to the package root.
    private static func findSourceMetallib() -> URL? {
        let fm = FileManager.default

        if let env = ProcessInfo.processInfo.environment["MLX_METALLIB_SOURCE"],
           !env.isEmpty,
           fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }

        // Anchor at the test bundle path -- much more reliable than
        // _NSGetExecutablePath under `swift test`.
        let bundle = Bundle(for: BundleSentinel.self)
        var cursor = bundle.bundleURL
        for _ in 0..<12 {
            if cursor.lastPathComponent == ".build" {
                let candidates: [URL] = [
                    cursor.appendingPathComponent("debug/mlx.metallib"),
                    cursor.appendingPathComponent("release/mlx.metallib"),
                    cursor.appendingPathComponent("arm64-apple-macosx/debug/mlx.metallib"),
                    cursor.appendingPathComponent("arm64-apple-macosx/release/mlx.metallib"),
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

    /// Load a model into a fresh `BatchScheduler` and return both. Caller
    /// is responsible for `await scheduler.unloadModel()` when finished
    /// (use `defer` in the test).
    ///
    /// - Throws: `LiveFixtureSkip` if the model isn't on disk, or if the
    ///   metallib isn't available.
    static func loadScheduler(
        modelID: String,
        maxConcurrentRequests: Int = 4,
        memoryBudgetBytes: Int? = nil
    ) async throws -> (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL) {
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

        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )

        let scheduler = BatchScheduler(
            maxConcurrentRequests: maxConcurrentRequests,
            pendingTimeout: .seconds(60),
            defaultMaxTokens: 256
        )
        await scheduler.loadModel(container: container, modelId: modelID)

        return (scheduler, container, directory)
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

/// Collect events from `BatchScheduler.submit(...)` into a structured
/// result so test assertions can be expressed simply.
struct CollectedGeneration {
    var chunks: [String] = []
    var info: (promptTokens: Int, completionTokens: Int, tokensPerSecond: Double)?
    var error: String?

    var fullText: String { chunks.joined() }
    var didError: Bool { error != nil }
    var didFinish: Bool { info != nil || error != nil }
}

/// Submit a request to a scheduler and collect the full event stream into a
/// structured result.
///
/// Implemented as a free function (not an actor extension) so the scheduler
/// is not held while we iterate. If we held the actor across the
/// `for await event in stream` loop, no other request could be admitted,
/// `cancel(requestId:)` couldn't run, and `requestCompleted` would be
/// queued behind us -- the concurrent and cancellation tests would all
/// deadlock or stall.
func collect(
    from scheduler: BatchScheduler,
    request: ChatCompletionRequest,
    requestId: String? = nil
) async -> CollectedGeneration {
    let stream = await scheduler.submit(request: request, requestId: requestId)
    var collected = CollectedGeneration()
    for await event in stream {
        switch event {
        case .chunk(let text):
            collected.chunks.append(text)
        case .info(let prompt, let completion, let tps):
            collected.info = (prompt, completion, tps)
        case .error(let message):
            collected.error = message
        }
    }
    return collected
}
