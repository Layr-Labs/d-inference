import Foundation

extension OnboardingFlowModel {
    func loadPreparationCatalog() async {
        guard !freezesAutomaticProgress else { return }
        guard let preparationService else {
            preparationFailureDetail = "The model preparation service is unavailable."
            preparationPhase = .catalogFailed
            return
        }
        let revision = operationRevision
        preparationFailureDetail = nil
        preparationPhase = .loadingCatalog
        do {
            let plan = try await preparationService.fetchPlan()
            guard revision == operationRevision, !Task.isCancelled else { return }
            applyPreparationPlan(plan)
            preparationPhase = .choosingModel
        } catch is CancellationError {
            return
        } catch OnboardingPreparationServiceError.noCompatibleModel {
            guard revision == operationRevision else { return }
            preparationChoices = []
            selectedModelID = nil
            preparationFailureDetail = OnboardingPreparationServiceError.noCompatibleModel.localizedDescription
            preparationPhase = .noCompatibleModel
        } catch {
            guard revision == operationRevision else { return }
            preparationFailureDetail = error.localizedDescription
            preparationPhase = .catalogFailed
        }
    }

    func selectPreparationModel(id: String) {
        guard preparationPhase == .choosingModel,
              preparationChoices.contains(where: { $0.id == id })
        else { return }
        selectedModelID = id
        let isAvailable = preparationChoices.first(where: { $0.id == id })?.isInstalled == true
            || downloadCompletedModelID == id
        preparationProgress = isAvailable ? 1 : 0
        preparationFailureDetail = nil
    }

    func startPreparation() {
        guard preparationTask == nil, let choice = selectedPreparationChoice else { return }
        let service = preparationService
        preparationTask = Task { [weak self] in
            guard let self, let service else { return }
            defer { self.preparationTask = nil }
            if choice.isInstalled || self.downloadCompletedModelID == choice.id {
                await self.startProvider(modelID: choice.id, using: service)
            } else {
                await self.downloadAndStart(model: choice, using: service)
            }
        }
    }

    func retryPreparation() {
        switch preparationPhase {
        case .catalogFailed, .noCompatibleModel:
            Task { await loadPreparationCatalog() }
        case .startFailed:
            guard preparationTask == nil, let selectedModelID, let preparationService else { return }
            preparationTask = Task { [weak self] in
                guard let self else { return }
                defer { self.preparationTask = nil }
                await self.startProvider(modelID: selectedModelID, using: preparationService)
            }
        case .downloadFailed:
            startPreparation()
        default:
            break
        }
    }

    func previewPreparationRetry() {
        guard freezesAutomaticProgress else {
            retryPreparation()
            return
        }
        preparationProgress = 1
        preparationPhase = .ready
        providerStartCompleted = true
    }

    func applyPreparationPlan(_ plan: OnboardingPreparationPlan) {
        preparationChoices = plan.choices
        if let selectedModelID,
           plan.choices.contains(where: { $0.id == selectedModelID }) {
            self.selectedModelID = selectedModelID
        } else {
            selectedModelID = plan.recommendedModelID
        }
        let selectedModelIsAvailable = selectedPreparationChoice?.isInstalled == true
            || downloadCompletedModelID == selectedModelID
        preparationProgress = selectedModelIsAvailable ? 1 : max(0, preparationProgress)
    }

    private func downloadAndStart(
        model: OnboardingModelChoice,
        using service: any OnboardingPreparationServicing
    ) async {
        let revision = operationRevision
        var bytesByFile: [String: Int64] = [:]
        var totalByFile: [String: Int64] = [:]
        var receivedDone = false
        preparationFailureDetail = nil
        preparationPhase = .downloading

        do {
            for try await event in service.downloadEvents(modelID: model.id) {
                guard revision == operationRevision, !Task.isCancelled else { return }
                switch event {
                case .progress(let file, let bytes, let total):
                    bytesByFile[file] = max(0, bytes)
                    if let total { totalByFile[file] = max(0, total) }
                    let downloaded = bytesByFile.values.reduce(0, +)
                    let knownTotal = totalByFile.values.reduce(0, +)
                    let total = max(model.sizeBytes, knownTotal, downloaded)
                    preparationProgress = total > 0
                        ? min(0.99, Double(downloaded) / Double(total))
                        : 0
                    preparationPhase = .downloading
                case .verifying:
                    preparationProgress = max(preparationProgress, 0.99)
                    preparationPhase = .verifying
                case .done:
                    receivedDone = true
                    downloadCompletedModelID = model.id
                    preparationProgress = 1
                case .error(let message):
                    throw ModelCatalogCLIError.downloadFailed(message)
                }
            }
            guard receivedDone else {
                throw ModelCatalogCLIError.downloadFailed(
                    "The model download ended before the CLI confirmed completion."
                )
            }
            await startProvider(modelID: model.id, using: service)
        } catch is CancellationError {
            return
        } catch {
            guard revision == operationRevision else { return }
            preparationFailureDetail = error.localizedDescription
            preparationPhase = .downloadFailed
        }
    }

    private func startProvider(
        modelID: String,
        using service: any OnboardingPreparationServicing
    ) async {
        let revision = operationRevision
        preparationFailureDetail = nil
        preparationProgress = 1
        preparationPhase = .startingProvider
        providerStartCompleted = false
        do {
            try await service.startProvider(modelID: modelID)
            guard revision == operationRevision, !Task.isCancelled else { return }
            try await waitForProviderEvidence(modelID: modelID, revision: revision)
            guard revision == operationRevision, !Task.isCancelled else { return }
            providerStartCompleted = true
            preparationPhase = .ready
        } catch is CancellationError {
            return
        } catch {
            guard revision == operationRevision else { return }
            providerStartCompleted = false
            preparationFailureDetail = error.localizedDescription
            preparationPhase = .startFailed
        }
    }

    private func waitForProviderEvidence(modelID: String, revision: Int) async throws {
        let deadline = ContinuousClock.now + preparationEvidenceTimeout
        while revision == operationRevision, !Task.isCancelled {
            if providerEvidenceProvider().reportsStarted(modelID: modelID) {
                return
            }
            guard ContinuousClock.now < deadline else {
                throw OnboardingPreparationServiceError.providerEvidenceTimedOut(modelID)
            }
            guard await pause(preparationEvidencePollInterval) else {
                throw CancellationError()
            }
        }
        throw CancellationError()
    }
}
