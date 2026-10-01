import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
    static func autopilotAnswer(_ input: String?) -> Bool {
        ["y", "yes"].contains(input?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    func resolveAutopilotChoice(_ config: ProviderConfig) throws -> Bool {
        if local || config.coordinator.privateOnly {
            if autopilot == true { throw ValidationError("Autopilot requires a network provider.") }
            return false
        }
        if !model.isEmpty && (autopilot ?? config.backend.modelAutopilot.hasConsent) {
            throw ValidationError("Autopilot advertises downloaded network models; use --no-autopilot with --model for a manual selection.")
        }
        if let autopilot {
            return autopilot
        }
        let settings = config.backend.modelAutopilot
        if settings.consentRecorded { return settings.hasConsent }
        guard isatty(STDIN_FILENO) != 0, !foreground, !local, !config.coordinator.privateOnly,
              model.isEmpty, !all else { return false }
        return Self.promptAutopilotChoice()
    }

    static func promptAutopilotChoice(
        readInput: () -> String? = { readLine() },
        emit: (String) -> Void = { print($0, terminator: "") }
    ) -> Bool {
        emit("Autopilot - Experimental, shadow-first rollout\n")
        emit("Shadow mode is the default: proposed model changes are recorded, not activated.\n")
        emit("Saying yes reports all downloaded models supported by our network; it does not activate live control.\n")
        emit("No extra model selection or downloads. Your saved model, preload and idle preferences stay unchanged.\n")
        emit("When we turn Autopilot on, it will choose among those cached models to improve network utilization.\n")
        emit("Downloaded files stay on disk. You can pause or disable Autopilot at any time.\n")
        emit("Interested in joining the Autopilot rollout? [y/N]: ")
        return autopilotAnswer(readInput())
    }
}

@discardableResult
func saveAutopilotEnrollment(enabled: Bool, models: [String], configPath: String?) throws -> URL {
    let selected = enabled ? try validatedAutopilotSelection(models) : []
    return try withMutableConfig(configPath: configPath) { path, config in
        var settings = config.backend.modelAutopilot
        settings.enabled = enabled
        settings.consentRecorded = true
        settings.paused = false
        settings.selectedModels = enabled ? selected : settings.selectedModels
        settings.pinnedModels = settings.pinnedModels.filter { settings.selectedModels.contains($0) }
        settings.revision = UUID().uuidString
        config.backend.modelAutopilot = settings
        try ConfigManager.save(config, to: path)
        return path
    }
}

func validatedAutopilotSelection(_ models: [String]) throws -> [String] {
    let selected = Array(Set(models)).sorted()
    let settings = ModelAutopilotSettings(enabled: true, consentRecorded: true,
        selectedModels: selected, revision: "selection")
    guard settings.hasConsent else {
        throw ValidationError("Select 1 to 256 Autopilot models with nonempty IDs of at most 256 UTF-8 bytes.")
    }
    return selected
}

extension Start {
    func downloadedAutopilotInventory(snapshot: RuntimeSnapshot, coordinatorURL: String,
                                     runtimeCapabilities: Set<ProviderRuntimeCapability>) async throws -> [String] {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL)
        let catalog = try await client.fetchCatalogSnapshot(typeFilter: "text", includeAliases: true)
        let local = snapshot.hardware.map { ModelScanner.scanAllModels(hardwareInfo: $0) } ?? []
        let verifier = ModelDownloader(catalogClient: client,runtimeCapabilities: runtimeCapabilities)
        let approved = autopilot == true || !snapshot.config.backend.modelAutopilot.hasConsent
            ? nil : Set(snapshot.config.backend.modelAutopilot.selectedModels)
        print("  Checking downloaded network models (no model downloads)...")
        return try await Self.verifiedAutopilotInventory(local: local, catalog: catalog.models,
            memoryGb: Double(snapshot.hardware?.memoryGb ?? 0), runtimeCapabilities: runtimeCapabilities,
            approved: approved, verify: { try await verifier.verifySelectedModel($0) },
            excluded: { printError("Not reporting \($0): downloaded build could not be verified (\($1)).") })
    }

    static func verifiedAutopilotInventory(
        local: [ModelInfo], catalog: [CatalogModel], memoryGb: Double,
        runtimeCapabilities: Set<ProviderRuntimeCapability>, approved: Set<String>? = nil,
        verify: (CatalogModel) async throws -> Void,
        excluded: (String, any Error) -> Void = { _, _ in }
    ) async throws -> [String] {
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var verified: [String] = []
        var seen = Set<String>()
        for model in local.sorted(by: { $0.id < $1.id }) {
            guard seen.insert(model.id).inserted, approved?.contains(model.id) ?? true,
                  let entry = byID[model.id], entry.active != false,
                  (entry.minRamGb ?? 0) <= Int(memoryGb),
                  model.id.utf8.count <= 256, !model.id.isEmpty,
                  EngineV2SupportedModels.isSupported(model: model),
                  ModelRuntimeRequirements.isEligible(modelID: model.id,
                      catalogRequirements: entry.requiredProviderCapabilities, available: runtimeCapabilities),
                  Self.modelFitsBudget(sizeGb: model.estimatedMemoryGb, memoryGb: memoryGb) else { continue }
            do {
                try Task.checkCancellation()
                try await verify(entry)
                try Task.checkCancellation()
                verified.append(model.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                excluded(model.id, error)
            }
        }
        try Task.checkCancellation()
        guard !verified.isEmpty else {
            throw ValidationError("No verified downloaded models supported by the network are available. Autopilot was not enrolled; download a supported model separately or use --no-autopilot.")
        }
        return try validatedAutopilotSelection(verified)
    }
}
