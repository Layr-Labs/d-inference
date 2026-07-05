// Start interactive catalog picker: build picker entries from the catalog,
// budget/fit + rollout filtering, fallback selection, and the prompt flow.
import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
    // MARK: - Interactive Catalog Picker

    /// Entry shown in the interactive TUI model picker.
    ///
    /// `downloaded` is computed from an UNFILTERED on-disk check (not the
    /// available-memory-filtered scan) so a fully-downloaded model that exceeds
    /// available RAM still reads "downloaded (won't fit)" rather than "not
    /// downloaded". `resumable` flags a build whose foreground download was
    /// interrupted (staging on disk) so the picker can show "resuming".
    struct PickerEntry: Equatable {
        let id: String
        let catalogModel: CatalogModel
        let displayName: String
        let sizeGb: Double
        let minRamGb: Int?
        let downloaded: Bool
        var resumable: Bool = false
    }

    struct PickerCatalogRow {
        let model: CatalogModel
        let displayName: String
    }

    /// Build picker entries from catalog rows and on-disk state. Pure (no IO) so
    /// the downloaded / won't-fit / resuming classification is unit-testable.
    ///
    /// - `downloadedIDs` MUST come from an UNFILTERED on-disk scan so a
    ///   present-but-too-big model still reads "downloaded".
    /// - `localMemoryByID` carries the on-disk estimated memory for sizing
    ///   downloaded rows (falls back to the catalog `size_gb` when absent).
    /// - `resumableIDs` are builds with interrupted-download staging on disk.
    /// - A not-yet-downloaded model whose declared `min_ram_gb` exceeds this box
    ///   is hidden; a downloaded one is always shown (with a won't-fit note in
    ///   the renderer).
    static func buildPickerEntries(
        rows: [PickerCatalogRow],
        downloadedIDs: Set<String>,
        localMemoryByID: [String: Double],
        resumableIDs: Set<String>,
        memoryGb: Double
    ) -> [PickerEntry] {
        var entries: [PickerEntry] = rows.compactMap { row in
            let model = row.model
            let isDownloaded = downloadedIDs.contains(model.id)
            if !isDownloaded, let minRam = model.minRamGb, Double(minRam) > memoryGb {
                return nil
            }
            let size = isDownloaded ? (localMemoryByID[model.id] ?? model.sizeGb) : model.sizeGb
            return PickerEntry(
                id: model.id,
                catalogModel: model,
                displayName: row.displayName,
                sizeGb: size,
                minRamGb: model.minRamGb,
                downloaded: isDownloaded,
                resumable: !isDownloaded && resumableIDs.contains(model.id)
            )
        }
        // Downloaded first, then larger first.
        entries.sort { a, b in
            if a.downloaded != b.downloaded { return a.downloaded }
            return a.sizeGb > b.sizeGb
        }
        return entries
    }

    /// Memory held back for the OS before the per-model serving budget. Shared by
    /// the interactive TUI picker and the non-TTY fallback so both agree on what
    /// "fits".
    static let pickerOSReserveGb = 4.0

    /// Whether a single model of `sizeGb` can be served on a box with `memoryGb`
    /// RAM. One model is warm at a time, so this is an individual-fit check with
    /// the OS reserve held back.
    static func modelFitsBudget(sizeGb: Double, memoryGb: Double) -> Bool {
        sizeGb <= memoryGb - pickerOSReserveGb
    }

    /// Outcome of resolving a non-TTY fallback-picker input line.
    enum FallbackSelection: Equatable {
        case cancelled
        case selected([String])
        case rejected(String)
    }

    /// Resolve a fallback-picker input ("all" or comma-separated 1-based indices)
    /// into model IDs, rejecting any pick that can't fit in RAM — the non-TTY
    /// equivalent of the TUI refusing to toggle a won't-fit row. Pure + testable.
    /// Without this guard a scripted/piped `darkbloom start` could select a model
    /// that is on disk but too large for this box and always OOMs on load.
    static func resolveFallbackSelection(
        input rawInput: String,
        entries: [PickerEntry],
        memoryGb: Double
    ) -> FallbackSelection {
        let input = rawInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return .cancelled }
        let budget = memoryGb - pickerOSReserveGb
        func fits(_ e: PickerEntry) -> Bool { modelFitsBudget(sizeGb: e.sizeGb, memoryGb: memoryGb) }

        if input.lowercased() == "all" {
            let fitting = entries.filter(fits)
            guard !fitting.isEmpty else {
                return .rejected(
                    "No model fits in \(Int(memoryGb)) GB RAM (need ≤ \(String(format: "%.1f", budget)) GB per model).")
            }
            return .selected(fitting.map(\.id))
        }

        var picked: [PickerEntry] = []
        for token in input.split(separator: ",") {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard let n = Int(t) else {
                return .rejected("Invalid selection: '\(t)' is not a number.")
            }
            guard n >= 1, n <= entries.count else {
                return .rejected("Invalid selection: \(n) (must be 1-\(entries.count)).")
            }
            let entry = entries[n - 1]
            guard fits(entry) else {
                return .rejected(
                    "\(entry.displayName) (\(String(format: "%.1f", entry.sizeGb)) GB) needs more memory than this Mac has "
                        + "(\(Int(memoryGb)) GB RAM, ~\(String(format: "%.1f", budget)) GB usable). Choose a smaller model.")
            }
            picked.append(entry)
        }
        return .selected(picked.map(\.id))
    }

    private static let gemmaPublicID = "gemma-4-26b"
    private static let gemmaQATID = "gemma-4-26b-qat-4bit"
    private static let gemmaRollbackID = "gemma-4-26b-8bit"

    private func pickerCatalogRows(models: [CatalogModel], aliases: [CatalogAlias]) -> [PickerCatalogRow] {
        if aliases.isEmpty {
            let gemmaQATAvailable = models.contains { $0.id == Self.gemmaQATID }
            return models.compactMap { model in
                if shouldHideGemmaRolloutModel(model, qatAvailable: gemmaQATAvailable) || isHiddenPickerModel(model) {
                    return nil
                }
                return PickerCatalogRow(model: model, displayName: gemmaRolloutDisplayName(for: model) ?? model.displayName)
            }
        }

        var hiddenBuilds = Set<String>()
        var aliasDisplayByBuild: [String: String] = [:]
        for alias in aliases {
            hiddenBuilds.insert(alias.desiredBuild)
            if let previous = alias.previousBuild { hiddenBuilds.insert(previous) }
            for retired in alias.retiredBuilds ?? [] { hiddenBuilds.insert(retired) }

            let primary = alias.primaryBuild ?? alias.desiredBuild
            aliasDisplayByBuild[primary] = alias.displayName
        }

        return models.compactMap { model in
            if let displayName = aliasDisplayByBuild[model.id] {
                return PickerCatalogRow(model: model, displayName: displayName)
            }
            if hiddenBuilds.contains(model.id) || isHiddenPickerModel(model) {
                return nil
            }
            return PickerCatalogRow(model: model, displayName: model.displayName)
        }
    }

    private func isHiddenPickerModel(_ model: CatalogModel) -> Bool {
        if let metadata = model.metadata {
            if metadata["hidden_from_picker"] == .bool(true) { return true }
            if metadata["hide_standalone"] == .bool(true) { return true }
        }
        return model.displayName.localizedCaseInsensitiveContains("rollback")
    }

    private func gemmaRolloutDisplayName(for model: CatalogModel) -> String? {
        // Temporary Gemma 4 rollout shim. Remove after the coordinator alias
        // catalog contract is deployed and the picker consumes alias metadata.
        model.id == Self.gemmaQATID ? "Gemma 4 26B" : nil
    }

    private func shouldHideGemmaRolloutModel(_ model: CatalogModel, qatAvailable: Bool) -> Bool {
        guard qatAvailable else { return model.id == Self.gemmaRollbackID }
        return model.id == Self.gemmaPublicID || model.id == Self.gemmaRollbackID
    }

    /// Fetches the model catalog from the coordinator, shows an interactive
    /// terminal picker, downloads any missing models, and returns the
    /// selected model IDs.
    internal func interactiveCatalogPicker(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        coordinatorURL: String
    ) async throws -> [String] {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL)

        let catalogSnapshot: CatalogSnapshot
        do {
            catalogSnapshot = try await client.fetchCatalogSnapshot(typeFilter: "text", includeAliases: true)
        } catch {
            printError("Could not fetch model catalog from coordinator: \(error)")
            printError("hint: check your coordinator URL or use --model to specify models directly")
            throw ExitCode.failure
        }

        let catalog = pickerCatalogRows(models: catalogSnapshot.models, aliases: catalogSnapshot.aliases)

        guard !catalog.isEmpty else {
            printError("No models in the coordinator catalog.")
            throw ExitCode.failure
        }

        let memoryGb: Double = Double(snapshot.hardware?.memoryGb ?? 16)

        // "Downloaded" must be computed from an UNFILTERED on-disk scan: the
        // memory-filtered `snapshot.models` drops models too large for available
        // RAM, which would make a fully-downloaded-but-too-big model read "not
        // downloaded" forever on a marginal-RAM box. The filtered scan is only
        // used (via the renderer's budget check) to flag "won't fit".
        let allLocal = snapshot.hardware.map { ModelScanner.scanAllModels(hardwareInfo: $0) } ?? []
        let downloadedIDs = Set(allLocal.map(\.id))
        let localMemoryByID = Dictionary(allLocal.map { ($0.id, $0.estimatedMemoryGb) }, uniquingKeysWith: { first, _ in first })
        // Builds with an interrupted foreground download staged on disk: show
        // "resuming" so re-selecting finishes rather than restarts.
        let resumableIDs = Set(catalog.compactMap { row -> String? in
            guard !downloadedIDs.contains(row.model.id), let prefix = row.model.r2Prefix else { return nil }
            return ModelDownloader.hasResumableStaging(modelID: row.model.id, r2Prefix: prefix) ? row.model.id : nil
        })

        let entries = Start.buildPickerEntries(
            rows: catalog,
            downloadedIDs: downloadedIDs,
            localMemoryByID: localMemoryByID,
            resumableIDs: resumableIDs,
            memoryGb: memoryGb
        )

        guard !entries.isEmpty else {
            printError("No supported models fit in \(Int(memoryGb)) GB RAM.")
            throw ExitCode.failure
        }

        // Fall back to simple numbered picker if stdin is not a TTY.
        guard isatty(STDIN_FILENO) != 0 else {
            return try await fallbackPicker(entries: entries, memoryGb: memoryGb, client: client)
        }

        // Run the interactive TUI picker.
        let selectedIndices = try runModelPicker(entries: entries, memoryGb: memoryGb)

        guard !selectedIndices.isEmpty else {
            return []
        }

        // Download any selected models that aren't local yet.
        let missing = selectedIndices
            .map { entries[$0] }
            .filter { !$0.downloaded }

        if !missing.isEmpty {
            print()
            let downloader = ModelDownloader(catalogClient: client)
            for entry in missing {
                print("  Downloading \(entry.displayName) (\(String(format: "%.1f GB", entry.sizeGb)))...")
                do {
                    try await downloader.download(model: entry.catalogModel) { progress in
                        let pct: String
                        if let total = progress.bytesTotal, total > 0 {
                            pct = String(format: " %.0f%%", Double(progress.bytesDownloaded) / Double(total) * 100)
                        } else {
                            pct = ""
                        }
                        let mb = Double(progress.bytesDownloaded) / 1_048_576
                        print("    \(progress.file)  \(String(format: "%.1f MB", mb))\(pct)")
                    }
                    print("  \u{2713} Downloaded \(entry.displayName)")
                } catch {
                    printError("Failed to download \(entry.displayName): \(error)")
                    printError("hint: download manually with `darkbloom models download \(entry.id)`")
                    throw ExitCode.failure
                }
            }
            print()
        }

        return selectedIndices.map { entries[$0].id }
    }

    /// Simple numbered fallback picker for non-TTY environments.
    private func fallbackPicker(
        entries: [PickerEntry],
        memoryGb: Double,
        client: ModelCatalogClient
    ) async throws -> [String] {
        print()
        print("  Models (from coordinator catalog):")
        print()
        for (i, entry) in entries.enumerated() {
            let status: String
            if entry.downloaded {
                status = "downloaded"
            } else if entry.resumable {
                status = "resuming"
            } else {
                status = "not downloaded"
            }
            let sizeStr = String(format: "%.1f GB", entry.sizeGb)
            let ramStr = entry.minRamGb.map { " (>= \($0) GB RAM)" } ?? ""
            // Parity with the TUI: a downloaded-but-too-big model is shown but
            // flagged so a non-interactive caller knows it can't be served here.
            let fitStr = Start.modelFitsBudget(sizeGb: entry.sizeGb, memoryGb: memoryGb) ? "" : "  [won't fit]"
            print("    [\(i + 1)] \(entry.displayName)  \(sizeStr)\(ramStr)  [\(status)]\(fitStr)")
        }
        print()
        print("  Select models (comma-separated numbers, or 'all'): ", terminator: "")

        let selected: [PickerEntry]
        switch Start.resolveFallbackSelection(input: readLine() ?? "", entries: entries, memoryGb: memoryGb) {
        case .cancelled:
            return []
        case .rejected(let message):
            printError(message)
            printError("hint: pick a model that fits, or run on a Mac with more RAM")
            throw ExitCode.failure
        case .selected(let ids):
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            selected = ids.compactMap { byID[$0] }
        }

        let localIDs = Set(entries.filter(\.downloaded).map(\.id))
        let missing = selected.filter { !localIDs.contains($0.id) }
        if !missing.isEmpty {
            print()
            print("  Downloading \(missing.count) model(s)...")
            print()
            let downloader = ModelDownloader(catalogClient: client)
            for entry in missing {
                print("  Downloading \(entry.displayName) (\(String(format: "%.1f GB", entry.sizeGb)))...")
                do {
                    try await downloader.download(model: entry.catalogModel) { progress in
                        let mb = Double(progress.bytesDownloaded) / 1_048_576
                        print("    \(progress.file)  \(String(format: "%.1f MB", mb))")
                    }
                    print("  \(entry.displayName) downloaded.")
                } catch {
                    printError("Failed to download \(entry.displayName): \(error)")
                    printError("hint: download manually with `darkbloom models download \(entry.id)`")
                    throw ExitCode.failure
                }
            }
            print()
        }

        return selected.map(\.id)
    }

}
