import ArgumentParser
import Foundation
import ProviderCore

/// The normal picker controls startup preferences. Autopilot consent has its
/// own verified cached inventory; it must not replace the picker result.
struct StartModelSelection {
    let hostedModels: [String]
    let autopilotModels: [String]?
}

extension Start {
    static func prepareModelSelection(
        autopilot: Bool,
        select: () async throws -> [String],
        inventory: ([String]) async throws -> [String]
    ) async throws -> StartModelSelection {
        let hosted = try await select()
        guard !hosted.isEmpty else { throw ValidationError("No models selected.") }
        try Task.checkCancellation()
        let cached = autopilot ? try await inventory(hosted) : nil
        // The inventory holds only downloaded catalog models that verified, so a
        // model found only on disk is missing here even when nothing failed.
        // Name the models: blaming verification hides which one to drop.
        if let cached {
            let missing = hosted.filter { !cached.contains($0) }
            guard missing.isEmpty else {
                throw ValidationError("Autopilot can start only downloaded Darkbloom network models that pass verification. Not in the verified inventory: \(missing.joined(separator: ", ")). Choose network models, retry after any model update finishes, or use --no-autopilot.")
            }
        }
        return StartModelSelection(hostedModels: hosted, autopilotModels: cached)
    }

    /// No start asks a question without a terminal. A start that names no models (`--model`, `--all`) picks them in the
    /// picker (`selectStartupModels`), whose numbered list reads standard input when there is no terminal and waits
    /// forever on input that stays open, as a script's or an agent's can. So such a start stops here, in one line on
    /// standard error (exit 64), before anything is stopped or started. Only me (`mode` local) without a terminal takes
    /// the last selection still on this Mac, never the picker (`onlyMeModelsWithoutAsking`), and launchd's
    /// `--foreground` child the models its job names: neither reaches the picker.
    func requireModelsNamedWithoutTerminal(mode: LocalSettings.Mode) throws {
        guard mode != .local, !foreground, model.isEmpty, !all, isatty(STDIN_FILENO) == 0 else { return }
        let cli = BuildEnvironment.current.cliName
        printError("Without a terminal, `\(cli) start` can't ask which models to serve: add --model <id> "
            + "(`\(cli) models list` shows this Mac's models) or --all.")
        throw ExitCode.validationFailure
    }

    /// `--model` or `--all` as given, else the picker with downloads. `whenCatalogUnreachable`, for Only me: the
    /// models it serves when Darkbloom's catalog can't be read, instead of stopping.
    func selectStartupModels(snapshot: RuntimeSnapshot, config: ProviderConfig,
                             coordinatorURL: String,
                             runtimeCapabilities: Set<ProviderRuntimeCapability>,
                             autopilot: Bool,
                             whenCatalogUnreachable: (() -> [String])? = nil) async throws -> [String] {
        if !model.isEmpty {
            let known = Set(snapshot.models.map(\.id))
            return model.filter {
                known.contains($0) && ModelRuntimeRequirements.isEligible(modelID: $0, available: runtimeCapabilities)
            }
        }
        if all {
            return snapshot.models.compactMap {
                ModelRuntimeRequirements.isEligible(modelID: $0.id, available: runtimeCapabilities) ? $0.id : nil
            }
        }
        return try await interactiveCatalogPicker(snapshot: snapshot, config: config,
            coordinatorURL: coordinatorURL, runtimeCapabilities: runtimeCapabilities,
            reserveMode: autopilot ? .autopilotInventory : .selectedModels,
            whenCatalogUnreachable: whenCatalogUnreachable)
    }
}
