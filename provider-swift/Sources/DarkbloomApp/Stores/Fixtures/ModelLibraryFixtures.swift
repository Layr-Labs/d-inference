import Foundation

enum ModelLibraryFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_784_330_000)
    static let transferRate: Int64 = 72 * 1_048_576

    private static let gibibyte: Int64 = 1_073_741_824

    static func make(_ fixture: ModelLibraryFixture) -> (
        catalogState: ModelCatalogState,
        models: [ModelSummary],
        selectedModelID: ModelSummary.ID?
    ) {
        var models = baseModels
        var catalogState: ModelCatalogState = .available(lastUpdated: timestamp)
        var selectedModelID: ModelSummary.ID?

        switch fixture {
        case .ready:
            break

        case .catalogOffline:
            catalogState = .offline(
                message: "Darkbloom could not reach the model catalog.",
                showingCachedResults: true
            )

        case .tooLarge:
            selectedModelID = models[2].id

        case .resumableDownload:
            let modelIndex = 1
            let total = models[modelIndex].sizeBytes
            let downloaded = total * 42 / 100
            models[modelIndex].installation = .paused(ModelTransferProgress(
                downloadedBytes: downloaded,
                totalBytes: total,
                bytesPerSecond: 0,
                estimatedSecondsRemaining: nil,
                resumedBytes: total * 31 / 100
            ))
            selectedModelID = models[modelIndex].id

        case .failedVerification:
            let modelIndex = 1
            models[modelIndex].installation = .failed(ModelTransferFailure(
                reason: .verificationMismatch,
                message: "Verification failed. The downloaded weights do not match the catalog hash.",
                resumableProgress: nil
            ))
            selectedModelID = models[modelIndex].id
        }

        return (catalogState, models, selectedModelID)
    }

    private static var baseModels: [ModelSummary] {
        [
            ModelSummary(
                id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                displayName: "Llama 3.2 3B",
                family: "Llama",
                kind: .text,
                summary: "A compact private assistant for everyday writing and chat.",
                sizeBytes: 2 * gibibyte,
                minimumMemoryGB: 8,
                quantization: "4-bit",
                maxContextLength: 131_072,
                capabilities: [.textGeneration, .tools],
                origin: .catalog,
                fit: .fits,
                installation: .installed,
                runtime: .warm
            ),
            ModelSummary(
                id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                displayName: "Qwen 2.5 7B",
                family: "Qwen",
                kind: .text,
                summary: "A balanced multilingual model with strong tool use.",
                sizeBytes: 5 * gibibyte,
                minimumMemoryGB: 16,
                quantization: "4-bit",
                maxContextLength: 32_768,
                capabilities: [.textGeneration, .tools, .reasoning],
                origin: .catalog,
                fit: .fits,
                installation: .notInstalled,
                runtime: .cold
            ),
            ModelSummary(
                id: "mlx-community/DeepSeek-R1-Distill-Llama-70B-4bit",
                displayName: "DeepSeek R1 Distill 70B",
                family: "DeepSeek",
                kind: .text,
                summary: "A large reasoning model intended for higher-memory Macs.",
                sizeBytes: 40 * gibibyte,
                minimumMemoryGB: 48,
                quantization: "4-bit",
                maxContextLength: 131_072,
                capabilities: [.textGeneration, .reasoning],
                origin: .catalog,
                fit: .tooLarge(requiredMemoryGB: 48, availableMemoryGB: 32),
                installation: .notInstalled,
                runtime: .cold
            ),
            ModelSummary(
                id: "local/custom-mlx-model",
                displayName: "Custom MLX Model",
                family: nil,
                kind: .unknown,
                summary: "A model discovered locally that is not in the active catalog.",
                sizeBytes: 3 * gibibyte,
                minimumMemoryGB: nil,
                quantization: nil,
                maxContextLength: nil,
                capabilities: [],
                origin: .localOnly,
                fit: .unknown,
                installation: .installed,
                runtime: .cold
            ),
        ]
    }
}
