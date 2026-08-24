import Foundation
import Observation

enum ModelCatalogState: Equatable, Sendable {
    case loading
    case available(lastUpdated: Date)
    case offline(message: String, showingCachedResults: Bool)
}

enum ModelLibraryFixture: String, CaseIterable, Sendable {
    case ready
    case catalogOffline
    case tooLarge
    case resumableDownload
    case failedVerification
}

enum ModelLibraryActionResult: Equatable, Sendable {
    case applied
    case requiresCompatibilityConfirmation(requiredMemoryGB: Int, availableMemoryGB: Int)
    case unavailable(String)
    case invalidState
    case modelNotFound
}

@MainActor
@Observable
final class ModelLibraryStore {
    private(set) var catalogState: ModelCatalogState
    private(set) var models: [ModelSummary]
    private(set) var selectedModelID: ModelSummary.ID?
    private(set) var lastActionResult: ModelLibraryActionResult?

    /// Nil in fixture mode; the live store shells out to the `darkbloom` CLI.
    @ObservationIgnored
    private let liveCLI: (any ModelCatalogCLIRunning)?

    /// One consumer task per in-flight CLI download (cancel ⇒ pause ⇒ the
    /// child is terminated; its staged bytes stay on disk for resume).
    @ObservationIgnored
    private var downloadTasks: [ModelSummary.ID: Task<Void, Never>] = [:]

    /// Session token per download task so a superseded/cancelled pump never
    /// clears its replacement from `downloadTasks` on the way out.
    @ObservationIgnored
    private var downloadSessions: [ModelSummary.ID: UUID] = [:]

    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var started = false

    init(fixture: ModelLibraryFixture = .ready) {
        let state = ModelLibraryFixtures.make(fixture)
        catalogState = state.catalogState
        models = state.models
        selectedModelID = state.selectedModelID
        liveCLI = nil
    }

    /// Live mode: rows are built by `start()`/`refreshCatalog` from
    /// `models catalog/list --json` plus the daemon's state file; downloads
    /// are real `models download --json` child processes.
    init(live cli: any ModelCatalogCLIRunning) {
        catalogState = .loading
        models = []
        selectedModelID = nil
        liveCLI = cli
    }

    deinit {
        downloadTasks.values.forEach { $0.cancel() }
        backgroundTasks.values.forEach { $0.cancel() }
        refreshTask?.cancel()
    }

    var isLive: Bool { liveCLI != nil }

    var selectedModel: ModelSummary? {
        guard let selectedModelID else { return nil }
        return models.first { $0.id == selectedModelID }
    }

    var installedModels: [ModelSummary] {
        models.filter(\.isInstalled)
    }

    var activeTransfers: [ModelSummary] {
        models.filter {
            switch $0.installation {
            case .downloading, .paused, .verifying: true
            case .notInstalled, .installed, .failed: false
            }
        }
    }

    // MARK: - Live refresh

    /// Kick the first live load. Idempotent; a later call after an offline
    /// failure gives the catalog a fresh shot (e.g. re-entering the screen).
    func start() async {
        guard let liveCLI else { return }
        if started {
            if case .offline = catalogState { retryCatalog() }
            return
        }
        started = true
        await refreshCatalog(using: liveCLI, preserveCatalogStateOnError: true)
    }

    /// Force a live catalog/local-state reread after an external CLI
    /// transaction (for example, account unlink). Fixture stores are a no-op.
    func refresh() async {
        guard let liveCLI else { return }
        refreshTask?.cancel()
        refreshTask = nil
        started = true
        await refreshCatalog(using: liveCLI, preserveCatalogStateOnError: true)
    }

    private func refreshCatalog(
        using cli: any ModelCatalogCLIRunning,
        preserveCatalogStateOnError: Bool = false
    ) async {
        do {
            let snapshot = try await cli.fetchSnapshot()
            apply(snapshot: snapshot)
            catalogState = .available(lastUpdated: snapshot.fetchedAt)
            lastActionResult = .applied
        } catch is CancellationError {
            // Task teardown; whatever the caller already set stays.
        } catch {
            if preserveCatalogStateOnError, case .available = catalogState {
                return
            }
            catalogState = .offline(
                message: error.localizedDescription,
                showingCachedResults: !models.isEmpty
            )
        }
    }

    private func scheduleRefresh(preserveCatalogStateOnError: Bool = false) {
        guard let liveCLI, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCatalog(
                using: liveCLI,
                preserveCatalogStateOnError: preserveCatalogStateOnError
            )
            self.refreshTask = nil
        }
    }

    // MARK: - Selection

    func selectModel(id: ModelSummary.ID?) {
        guard id == nil || models.contains(where: { $0.id == id }) else {
            lastActionResult = .modelNotFound
            return
        }
        selectedModelID = id
        lastActionResult = .applied
    }

    func retryCatalog() {
        guard let liveCLI else {
            catalogState = .available(lastUpdated: ModelLibraryFixtures.timestamp)
            lastActionResult = .applied
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        catalogState = .loading
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCatalog(using: liveCLI)
            self.refreshTask = nil
        }
    }

    func clearLastActionResult() {
        lastActionResult = nil
    }

    // MARK: - Downloads

    @discardableResult
    func beginDownload(
        modelID: ModelSummary.ID,
        allowingIncompatibleModel: Bool = false
    ) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else {
            return record(.modelNotFound)
        }

        guard models[index].isAvailableFromCatalog else {
            return record(.unavailable("This model is not available in the current catalog."))
        }

        if case .loading = catalogState {
            return record(.unavailable("Wait for the catalog to finish loading."))
        }

        if case .offline = catalogState {
            return record(.unavailable("Reconnect to refresh the catalog before downloading."))
        }

        if case .tooLarge(let required, let available) = models[index].fit,
           !allowingIncompatibleModel {
            return record(.requiresCompatibilityConfirmation(
                requiredMemoryGB: required,
                availableMemoryGB: available
            ))
        }

        switch models[index].installation {
        case .notInstalled:
            if isLive {
                startLiveDownload(at: index, resumeCredit: 0)
                return record(.applied)
            }
            let progress = ModelTransferProgress(
                downloadedBytes: 0,
                totalBytes: models[index].sizeBytes,
                bytesPerSecond: ModelLibraryFixtures.transferRate
            )
            models[index].installation = .downloading(progress)
            return record(.applied)

        case .failed(let failure):
            if isLive {
                let credit = failure.isResumable
                    ? (failure.resumableProgress?.downloadedBytes ?? 0)
                    : 0
                startLiveDownload(at: index, resumeCredit: credit)
                return record(.applied)
            }
            let progress = failure.isResumable
                ? failure.resumableProgress ?? emptyProgress(for: models[index])
                : emptyProgress(for: models[index])
            models[index].installation = .downloading(progress)
            return record(.applied)

        case .downloading, .paused, .verifying, .installed:
            return record(.invalidState)
        }
    }

    @discardableResult
    func pauseDownload(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard case .downloading(let progress) = models[index].installation else {
            return record(.invalidState)
        }
        // Live pause = terminate the child. Its staged `.part` bytes stay on
        // disk, so the next `models download` resumes where it stopped. Set
        // the state BEFORE cancelling so the pump's cancellation path cannot
        // clobber it.
        models[index].installation = .paused(progress)
        if isLive {
            downloadSessions[modelID] = nil
            downloadTasks[modelID]?.cancel()
            downloadTasks[modelID] = nil
        }
        return record(.applied)
    }

    @discardableResult
    func resumeDownload(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }

        if isLive {
            let resumeCredit: Int64
            switch models[index].installation {
            case .paused(let paused):
                resumeCredit = paused.downloadedBytes
            case .failed(let failure) where failure.isResumable:
                guard let resumable = failure.resumableProgress else {
                    return record(.invalidState)
                }
                resumeCredit = resumable.downloadedBytes
            default:
                return record(.invalidState)
            }
            startLiveDownload(at: index, resumeCredit: resumeCredit)
            return record(.applied)
        }

        let progress: ModelTransferProgress
        switch models[index].installation {
        case .paused(let pausedProgress):
            progress = pausedProgress
        case .failed(let failure) where failure.isResumable:
            guard let resumableProgress = failure.resumableProgress else {
                return record(.invalidState)
            }
            progress = resumableProgress
        default:
            return record(.invalidState)
        }

        models[index].installation = .downloading(progress)
        return record(.applied)
    }

    // MARK: - Simulated transfer ticks (fixture previews only)

    @discardableResult
    func advanceDownload(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard !isLive else { return .applied } // live transfers ride the CLI stream
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard case .downloading(let current) = models[index].installation else {
            return record(.invalidState)
        }

        let increment = max(1, current.totalBytes / 4)
        let downloaded = min(current.totalBytes, current.downloadedBytes + increment)
        let remaining = max(0, current.totalBytes - downloaded)
        let eta = ModelLibraryFixtures.transferRate > 0
            ? Int(ceil(Double(remaining) / Double(ModelLibraryFixtures.transferRate)))
            : nil
        let next = ModelTransferProgress(
            downloadedBytes: downloaded,
            totalBytes: current.totalBytes,
            bytesPerSecond: ModelLibraryFixtures.transferRate,
            estimatedSecondsRemaining: eta,
            resumedBytes: current.resumedBytes
        )

        models[index].installation = downloaded == current.totalBytes
            ? .verifying(next)
            : .downloading(next)
        return record(.applied)
    }

    @discardableResult
    func finishVerification(
        modelID: ModelSummary.ID,
        succeeds: Bool
    ) -> ModelLibraryActionResult {
        guard !isLive else { return .applied } // verification outcome arrives as stream events
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard case .verifying = models[index].installation else {
            return record(.invalidState)
        }

        if succeeds {
            models[index].installation = .installed
        } else {
            models[index].installation = .failed(ModelTransferFailure(
                reason: .verificationMismatch,
                message: "The downloaded weights did not match the catalog hash.",
                resumableProgress: nil
            ))
        }
        return record(.applied)
    }

    // MARK: - Removal

    @discardableResult
    func removeModel(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard models[index].isInstalled else { return record(.invalidState) }
        guard models[index].runtime == .cold else {
            return record(.unavailable("Take this model offline before removing it."))
        }
        if let liveCLI {
            let removedID = models[index].id
            let taskID = UUID()
            backgroundTasks[taskID] = Task { [weak self] in
                guard let self else { return }
                defer { self.backgroundTasks[taskID] = nil }
                do {
                    try await liveCLI.removeModel(modelID: removedID)
                } catch is CancellationError {
                    return
                } catch {
                    _ = self.record(.unavailable(error.localizedDescription))
                    return
                }
                // Disk truth converges: local-only rows vanish, catalog rows
                // flip back to notInstalled.
                await self.refreshCatalog(using: liveCLI, preserveCatalogStateOnError: true)
            }
            return record(.applied)
        }
        if models[index].origin == .localOnly {
            let removedID = models[index].id
            models.remove(at: index)
            if selectedModelID == removedID { selectedModelID = nil }
        } else {
            models[index].installation = .notInstalled
        }
        return record(.applied)
    }

    // MARK: - Live download pump

    private func startLiveDownload(at index: Int, resumeCredit: Int64) {
        guard let liveCLI, !isDownloadActive(modelID: models[index].id) else { return }
        let model = models[index]
        models[index].installation = .downloading(ModelTransferProgress(
            downloadedBytes: 0,
            totalBytes: model.sizeBytes
        ))
        let session = UUID()
        let modelID = model.id
        downloadSessions[modelID] = session
        downloadTasks[modelID]?.cancel()
        downloadTasks[modelID] = Task { [weak self] in
            guard let self else { return }
            await self.pumpDownloadEvents(modelID: modelID, resumeCredit: resumeCredit, cli: liveCLI)
            // A superseded/cancelled pump must not clear its replacement.
            if self.downloadSessions[modelID] == session {
                self.downloadSessions[modelID] = nil
                self.downloadTasks[modelID] = nil
            }
        }
    }

    private func isDownloadActive(modelID: ModelSummary.ID) -> Bool {
        downloadSessions[modelID] != nil
    }

    /// Translate the CLI's NDJSON events into `ModelInstallationState`:
    /// per-file cumulative bytes are summed into one model-level progress
    /// bar (denominator = catalog size, which covers files the stream hasn't
    /// reached); `verifying`/`done` flip phases; a thrown stream (or the
    /// CLI's terminal error line) becomes a resumable `.failed` whenever any
    /// bytes are safely staged.
    private func pumpDownloadEvents(
        modelID: ModelSummary.ID,
        resumeCredit: Int64,
        cli: any ModelCatalogCLIRunning
    ) async {
        var fileBytes: [String: Int64] = [:]
        var fileTotals: [String: Int64] = [:]
        var rateSample: (date: Date, downloaded: Int64)?
        var rate: Int64 = 0

        func catalogTotalBytes() -> Int64 {
            index(of: modelID).map { models[$0].sizeBytes } ?? 0
        }

        func aggregateProgress(now: Date) -> ModelTransferProgress {
            let downloaded = fileBytes.values.reduce(0, +)
            let knownTotal = fileTotals.values.reduce(0, +)
            let total = max(catalogTotalBytes(), knownTotal, downloaded)
            if let sample = rateSample, now.timeIntervalSince(sample.date) >= 0.5 {
                let dt = now.timeIntervalSince(sample.date)
                rate = Int64(max(0, Double(downloaded - sample.downloaded) / dt))
                rateSample = (now, downloaded)
            } else if rateSample == nil {
                rateSample = (now, downloaded)
            }
            let remaining = max(0, total - downloaded)
            let eta = rate > 0 && remaining > 0 ? Int(ceil(Double(remaining) / Double(rate))) : nil
            return ModelTransferProgress(
                downloadedBytes: downloaded,
                totalBytes: total,
                bytesPerSecond: rate,
                estimatedSecondsRemaining: eta,
                // The resumed-prefix credit only counts once the CLI has
                // actually reported those on-disk bytes back to us.
                resumedBytes: min(resumeCredit, downloaded)
            )
        }

        do {
            for try await event in cli.downloadEvents(modelID: modelID) {
                try Task.checkCancellation()
                guard let index = index(of: modelID) else { return }
                switch event {
                case .progress(let file, let bytes, let total):
                    fileBytes[file] = bytes
                    if let total { fileTotals[file] = total }
                    models[index].installation = .downloading(aggregateProgress(now: Date()))
                case .verifying:
                    if let progress = models[index].installation.progress {
                        models[index].installation = .verifying(progress)
                    }
                case .done:
                    models[index].installation = .installed
                case .error(let message):
                    throw ModelCatalogCLIError.downloadFailed(message)
                }
            }
        } catch is CancellationError {
            // Pause already wrote the .paused state; leave it alone.
        } catch {
            guard let index = index(of: modelID) else { return }
            let progress = fileBytes.isEmpty
                ? nil
                : aggregateProgress(now: Date())
            models[index].installation = .failed(ModelTransferFailure(
                reason: Self.classifyTransferFailure(error),
                message: error.localizedDescription,
                resumableProgress: progress
            ))
        }

        // Converge with disk + daemon truth: a finished download publishes
        // into `models list --json`; warm state may have shifted too.
        await refreshCatalog(using: cli, preserveCatalogStateOnError: true)
    }

    private static func classifyTransferFailure(_ error: Error) -> ModelTransferFailureReason {
        let text = error.localizedDescription.lowercased()
        if text.contains("hash") || text.contains("mismatch") || text.contains("aggregate") {
            return .verificationMismatch
        }
        if text.contains("disk") || text.contains("space") {
            return .insufficientDiskSpace
        }
        switch error {
        case ModelCatalogCLIError.cliNotFound, ModelCatalogCLIError.exited,
             ModelCatalogCLIError.timedOut, ModelCatalogCLIError.unreadableOutput:
            return .network
        default:
            return .unknown
        }
    }

    // MARK: - Snapshot → rows

    /// Rebuild rows from a live snapshot. In-flight installation states
    /// (downloading/paused/verifying/failed) are PRESERVED: a staged
    /// download is invisible to the scanner, so the snapshot can't see it.
    /// The one exception: once the local scan contains the model, disk truth
    /// wins (publish racing the stream has resolved as success).
    private func apply(snapshot: ModelLibrarySnapshot) {
        let localIDs = Set(snapshot.local.map(\.id))
        let catalogIDs = Set(snapshot.catalog.map(\.id))
        let existingByID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [ModelSummary] = snapshot.catalog.map { entry in
            let installed = localIDs.contains(entry.id)
            var installation: ModelInstallationState = installed ? .installed : .notInstalled
            if !installed, let preserved = Self.preservedTransferState(of: existingByID[entry.id]) {
                installation = preserved
            }
            return ModelSummary(
                id: entry.id,
                displayName: entry.displayName,
                family: entry.family,
                kind: Self.kind(for: entry.modelType),
                summary: entry.description ?? "",
                sizeBytes: entry.totalSizeBytes ?? Int64((entry.sizeGb * 1_000_000_000).rounded()),
                minimumMemoryGB: entry.minRamGb,
                quantization: entry.quantization,
                maxContextLength: entry.maxContextLength,
                capabilities: (entry.capabilities ?? []).map(ModelCapability.init(rawValue:)),
                origin: .catalog,
                fit: Self.fit(for: entry, memoryGB: snapshot.physicalMemoryGB),
                installation: installation,
                runtime: Self.runtime(for: entry.id, snapshot: snapshot)
            )
        }

        rows += snapshot.local
            .filter { !catalogIDs.contains($0.id) }
            .map { entry in
                ModelSummary(
                    id: entry.id,
                    displayName: entry.id.split(separator: "/").last.map(String.init) ?? entry.id,
                    family: nil,
                    kind: Self.kind(for: entry.modelType),
                    summary: "A model discovered locally that is not in the active catalog.",
                    sizeBytes: Int64(clamping: entry.sizeBytes),
                    minimumMemoryGB: nil,
                    quantization: entry.quantization,
                    maxContextLength: nil,
                    capabilities: [],
                    origin: .localOnly,
                    fit: .unknown,
                    installation: .installed,
                    runtime: Self.runtime(for: entry.id, snapshot: snapshot)
                )
            }

        models = rows
    }

    private static func preservedTransferState(of model: ModelSummary?) -> ModelInstallationState? {
        guard let model else { return nil }
        switch model.installation {
        case .downloading, .paused, .verifying, .failed:
            return model.installation
        case .notInstalled, .installed:
            return nil
        }
    }

    private static func kind(for modelType: String?) -> ModelKind {
        switch modelType?.lowercased() {
        case "text": .text
        case "vision", "vlm", "multimodal": .vision
        case "embeddings", "embedding": .embeddings
        default: .unknown
        }
    }

    private static func fit(for entry: CLICatalogModel, memoryGB: Int?) -> ModelFit {
        guard let required = entry.minRamGb, let available = memoryGB else { return .unknown }
        return required <= available
            ? .fits
            : .tooLarge(requiredMemoryGB: required, availableMemoryGB: available)
    }

    private static func runtime(for modelID: String, snapshot: ModelLibrarySnapshot) -> ModelRuntimeState {
        if snapshot.servingModelID == modelID { return .serving }
        if snapshot.warmModelIDs.contains(modelID) { return .warm }
        return .cold
    }

    // MARK: - Internals

    private func index(of modelID: ModelSummary.ID) -> Int? {
        models.firstIndex { $0.id == modelID }
    }

    private func emptyProgress(for model: ModelSummary) -> ModelTransferProgress {
        ModelTransferProgress(
            downloadedBytes: 0,
            totalBytes: model.sizeBytes,
            bytesPerSecond: ModelLibraryFixtures.transferRate
        )
    }

    @discardableResult
    private func record(_ result: ModelLibraryActionResult) -> ModelLibraryActionResult {
        lastActionResult = result
        return result
    }
}
