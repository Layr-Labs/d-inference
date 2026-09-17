// Copyright © 2026 Eigen Labs.
//
// Shared checkpoint → `ModelContainer` loading (v0.7.5 one-engine).
//
// Both slot owners (`ProviderLoop.ensureModelLoaded` and the standalone
// server's lazy load) share architecture-aware factory selection. Native
// Qwen4 uses its full VLM factory only for the qualified owned multimodal
// declaration; text overlays and unqualified identities retain the text factory.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

enum ModelContainerLoading {
    enum FactorySelection: Equatable {
        case text
        case vision
    }

    /// Architecture selection is explicit, separate from media advertisement.
    /// Qwen4 text models filter vision keys before evaluation. The qualified
    /// VLM wrapper instead retains its tower using the original staged config.
    /// No factory rewrites the checkpoint configuration during loading.
    static func factorySelection(for configuration: [String: Any], modelID: String? = nil) -> FactorySelection {
        ModelMediaPolicy.advertisesMedia(configuration, modelID: modelID) ? .vision : .text
    }

    static func factorySelection(at directory: URL, modelID: String?) -> FactorySelection {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
            let configuration = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .text }
        return factorySelection(for: configuration, modelID: modelID)
    }

    /// Load the checkpoint at `directory`, VLM-aware.
    static func loadContainer(from directory: URL, modelID: String? = nil) async throws -> MLXLMCommon.ModelContainer {
        let selection = factorySelection(at: directory, modelID: modelID)
        let adopted = try Qwen4ExpPLEResidency.adoptForLoadIfQwen4Exp(directory: directory)
        // Construction owns a temporary binding. A native Qwen4 model takes
        // its own lease, so unload/deinit does not depend on path bookkeeping.
        defer { if adopted { Qwen4ExpPLEResidency.release(directory: directory) } }
        var loaded: MLXLMCommon.ModelContainer?
        do {
            let container: MLXLMCommon.ModelContainer
            if selection == .vision {
                container = try await VLMModelFactory.shared.loadContainer(
                    from: directory, using: LocalTokenizerLoader())
            } else {
                container = try await LLMModelFactory.shared.loadContainer(
                    from: directory, using: LocalTokenizerLoader())
            }
            loaded = container
            try await container.perform { context in
                try (context.model as? any Qwen4ExpExternalPLEValidating)?.validateExternalPLEResources()
            }
            return container
        } catch {
            await releaseExternalResources(in: loaded)
            throw error
        }
    }

    /// Call only after engine drain (or on a failed load before serving).
    /// Explicit closure drops mmap handles and bounded row buffers before
    /// survivor grants grow; model deinit remains the backstop.
    static func releaseExternalResources(in container: MLXLMCommon.ModelContainer?) async {
        guard let container else { return }
        await container.perform { context in
            (context.model as? any Qwen4ExpExternalPLEReleasing)?.releaseExternalPLEResources()
        }
    }
}
