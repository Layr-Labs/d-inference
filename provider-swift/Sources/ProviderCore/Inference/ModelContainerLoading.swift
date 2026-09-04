// Copyright © 2026 Eigen Labs.
//
// Shared checkpoint → `ModelContainer` loading (v0.7.5 one-engine).
//
// Both slot owners (`ProviderLoop.ensureModelLoaded` and the standalone
// server's lazy load) pick the model factory the same way: a checkpoint
// whose config.json declares `vision_config` loads via `VLMModelFactory`
// so image/video requests can use its vision path and CBv2 can directly use
// the wrapper-owned text tower; everything else loads via `LLMModelFactory`.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

enum ModelContainerLoading {
    #if DEBUG
    /// Test seam: stub containers keyed by snapshot directory, consulted
    /// before the model factories so a suite can drive `ensureModelLoaded`
    /// PAST the container load without weights. Keyed so a suite only ever
    /// intercepts its own fixture path; parallel suites loading elsewhere
    /// fall through to the real factories untouched.
    private static let stubLock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: @Sendable () -> MLXLMCommon.ModelContainer] = [:]

    static func registerContainerForTesting(
        at directory: URL, _ make: @escaping @Sendable () -> MLXLMCommon.ModelContainer
    ) {
        stubLock.withLock { stubs[stubKey(directory)] = make }
    }

    static func unregisterContainerForTesting(at directory: URL) {
        stubLock.withLock { _ = stubs.removeValue(forKey: stubKey(directory)) }
    }

    private static func stubKey(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }
    #endif

    /// Load the checkpoint at `directory`, VLM-aware.
    static func loadContainer(from directory: URL) async throws -> MLXLMCommon.ModelContainer {
        #if DEBUG
        if let make = stubLock.withLock({ stubs[stubKey(directory)] }) {
            return make()
        }
        #endif
        if ProviderLoop.modelIsVLM(at: directory) {
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: LocalTokenizerLoader()
            )
        }
        return try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )
    }
}
