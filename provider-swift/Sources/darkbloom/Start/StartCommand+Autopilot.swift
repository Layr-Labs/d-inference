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
        if all && (autopilot ?? config.backend.modelAutopilot.hasConsent) {
            throw ValidationError("Autopilot requires explicit model selection; use the picker or repeat --model.")
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
        emit("Saying yes records your interest and selected models; it does not activate live control.\n")
        emit("A later live rollout can load and unload only those selected models based on network demand.\n")
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
        if enabled { config.backend.enabledModels = settings.selectedModels }
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
    func verifyAutopilotSelection(_ ids: [String], snapshot: RuntimeSnapshot,
                                  coordinatorURL: String, runtimeCapabilities: Set<ProviderRuntimeCapability>) async throws {
        _ = try validatedAutopilotSelection(ids)
        if !model.isEmpty && Set(ids) != Set(model) { throw ValidationError("Every requested Autopilot model must be downloaded and supported by this Mac.") }
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL)
        let catalog = try await client.fetchCatalogSnapshot(typeFilter: "text", includeAliases: true)
        let byID = Dictionary(catalog.models.map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        let local = snapshot.hardware.map { ModelScanner.scanAllModels(hardwareInfo: $0) } ?? []
        let byLocalID = Dictionary(local.map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        let verifier = ModelDownloader(catalogClient: client,runtimeCapabilities: runtimeCapabilities)
        print("  Verifying selected builds before recording Autopilot enrollment...")
        for id in ids {
            guard let entry = byID[id], entry.active != false,
                  (entry.minRamGb ?? 0) <= Int(snapshot.hardware?.memoryGb ?? 0),
                  ModelRuntimeRequirements.isEligible(modelID:id,catalogRequirements:entry.requiredProviderCapabilities,available:runtimeCapabilities),
                  let localModel = byLocalID[id],
                  Self.modelFitsBudget(sizeGb:localModel.estimatedMemoryGb,memoryGb:Double(snapshot.hardware?.memoryGb ?? 0)) else {
                throw ValidationError("Selected model is not eligible on this Mac: \(id)")
            }
            try await verifier.verifySelectedModel(entry)
        }
    }
}
