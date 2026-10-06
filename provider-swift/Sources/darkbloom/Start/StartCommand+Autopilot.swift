import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
    static func autopilotAnswer(_ input: String?, defaultEnabled: Bool = false) -> Bool {
        let answer = input?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return answer.isEmpty ? defaultEnabled : ["y", "yes"].contains(answer)
    }

    func resolveAutopilotChoice(
        _ config: ProviderConfig,
        interactive: Bool = isatty(STDIN_FILENO) != 0,
        ask: (Bool) -> Bool = { Start.promptAutopilotChoice(defaultEnabled: $0) }
    ) throws -> Bool {
        if local || config.coordinator.privateOnly {
            if autopilot == true { throw ValidationError("Autopilot requires a network provider.") }
            return false
        }
        if let autopilot {
            return autopilot
        }
        let settings = config.backend.modelAutopilot
        guard interactive, !foreground, model.isEmpty, !all else { return settings.hasConsent }
        return ask(settings.hasConsent)
    }

    static func promptAutopilotChoice(
        defaultEnabled: Bool = false,
        readInput: () -> String? = { readLine() },
        emit: (String) -> Void = { print($0, terminator: "") }
    ) -> Bool {
        emit("Autopilot - Experimental, shadow-first rollout\n")
        emit("Shadow mode is the default: proposed model changes are recorded, not activated.\n")
        emit("Saying yes reports all downloaded models supported by our network; it does not activate live control.\n")
        emit("Choose your startup models and memory preferences in the usual selector next.\n")
        emit("When we turn Autopilot on, it will choose among those cached models to improve network utilization.\n")
        emit("Downloaded files stay on disk. You can pause or disable Autopilot at any time.\n")
        emit("Enable experimental Autopilot? \(defaultEnabled ? "[Y/n]" : "[y/N]"): ")
        return autopilotAnswer(readInput(), defaultEnabled: defaultEnabled)
    }
}

@discardableResult
func saveAutopilotEnrollment(enabled: Bool, models: [String], configPath: String?) throws -> URL {
    let selected = enabled ? try validatedAutopilotSelection(models) : []
    return try withMutableConfig(configPath: configPath) { path, config in
        var settings = config.backend.modelAutopilot
        if !enabled || !settings.hasConsent { settings.paused = false }
        settings.enabled = enabled
        settings.consentRecorded = true
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
                                     runtimeCapabilities: Set<ProviderRuntimeCapability>,
                                     selectedStartupModels: [String] = []) async throws -> [String] {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL)
        let catalog = try await client.fetchCatalogSnapshot(typeFilter: "text", includeAliases: true)
        let local = snapshot.hardware.map { ModelScanner.scanAllModels(hardwareInfo: $0) } ?? []
        let verifier = ModelDownloader(catalogClient: client,runtimeCapabilities: runtimeCapabilities)
        let approved = autopilot == true || !snapshot.config.backend.modelAutopilot.hasConsent
            ? nil : Set(snapshot.config.backend.modelAutopilot.selectedModels).union(selectedStartupModels)
        print("  Checking downloaded network models (no model downloads)...")
        return try await Self.verifiedAutopilotInventory(local: local, catalog: catalog.models,
            memoryGb: Double(snapshot.hardware?.memoryGb ?? 0), runtimeCapabilities: runtimeCapabilities,
            approved: approved, verifying: { print("    Verifying \($0)...") }, verify: { try await verifier.verifySelectedModel($0) },
            excluded: { printError("Not reporting \($0): downloaded build could not be verified (\($1)).") })
    }

    static func verifiedAutopilotInventory(
        local: [ModelInfo], catalog: [CatalogModel], memoryGb: Double,
        runtimeCapabilities: Set<ProviderRuntimeCapability>, approved: Set<String>? = nil,
        verifying: (String) -> Void = { _ in },
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
                verifying(model.id)
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
        if let approved, Set(verified) != approved {
            throw ValidationError("Could not validate every enrolled model. The recorded Autopilot inventory is unchanged; retry start, or explicitly refresh it with darkbloom autopilot models.")
        }
        guard !verified.isEmpty else {
            throw ValidationError("No verified downloaded models supported by the network are available. Autopilot was not enrolled; download a supported model separately or use --no-autopilot.")
        }
        return try validatedAutopilotSelection(verified)
    }
}
