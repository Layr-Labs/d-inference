import Foundation

extension EngineV2Bridge {
    func runModelCalibrationCell(_ cell: ModelCalibrationPolicy.Cell, tokens: [Int],
        requireNominalPosture: Bool,
        timeoutSeconds: Double = ModelCalibrationPolicy.maximumGroupSeconds) async -> Bool {
        let ids = (0..<cell.width).map { _ in "calibration-" + UUID().uuidString }
        for id in ids { modelCalibration.requests[id] = cell }
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000)) }
            catch { return }
            await self?.interruptModelCalibration(ids)
        }
        defer {
            timer.cancel()
            for id in ids {
                modelCalibration.requests.removeValue(forKey: id)
                modelCalibration.pendingObservations.removeValue(forKey: id)
            }
        }
        let successful = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                for id in ids {
                    group.addTask { await self.runModelCalibrationRequest(id, cell: cell, tokens: tokens) }
                }
                var success = true
                for await result in group { success = success && result }
                return success && !Task.isCancelled && !modelCalibration.interrupted
            }
        } onCancel: {
            Task { await self.interruptModelCalibration(ids) }
        }
        guard successful, !Task.isCancelled, !modelCalibration.interrupted,
            canSubmitWithNativeOwner(),
            !requireNominalPosture || calibrationPosturePermitsWork() else { return false }
        // Every pump and reservation has retired. Publish the cell atomically
        // on this actor; an invalid cell cannot roll back unrelated serving evidence.
        let observations = ids.flatMap { id in
            (modelCalibration.pendingObservations[id] ?? []).map { (id, $0) }
        }.sorted { $0.1.at < $1.1.at }
        for (id, observation) in observations {
            applyRateObservation(observation, requestID: id, calibration: true)
        }
        performanceUpdates?.notify()
        return true
    }

    private func runModelCalibrationRequest(_ id: String, cell: ModelCalibrationPolicy.Cell,
        tokens: [Int]) async -> Bool {
        guard !Task.isCancelled else { return false }
        let request = ChatCompletionRequest(model: modelId, messages: [],
            temperature: cell.sampled ? nil : 0, max_tokens: cell.outputTokens, seed: 42)
        let stream = await submitTokenized(promptTokens: tokens, request: request, requestId: id,
            cacheEnabled: false)
        var success = false
        for await event in stream {
            if Task.isCancelled { cancel(requestId: id); break }
            switch event {
            case .info: success = true
            case .error: success = false
            default: break
            }
        }
        if Task.isCancelled { cancel(requestId: id) }
        // Consumer terminal/stream cancellation is not physical retirement.
        // This handle is removed only after KV and service resources are freed.
        await pumpTasks[id]?.value
        await serviceBudget?.waitForRelease(ownerID: serviceOwnerPrefix + ":" + id)
        return success && !Task.isCancelled
    }

    func interruptModelCalibration(_ ids: [String]) {
        // A delayed timer/cancellation callback cannot interrupt a later cell
        // or a replacement session after these exact requests have retired.
        guard ids.contains(where: { modelCalibration.requests[$0] != nil }) else { return }
        modelCalibration.interrupted = true
        for id in ids { cancel(requestId: id) }
    }
}
