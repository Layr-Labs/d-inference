import Foundation

extension EngineV2Bridge {
    func runMimoCalibrationCell(_ cell: MimoCalibrationPolicy.Cell, tokens: [Int]) async -> Bool {
        let ids = (0..<cell.width).map { _ in "calibration-" + UUID().uuidString }
        for id in ids { mimoCalibration.requests[id] = cell }
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(MimoCalibrationPolicy.maximumGroupSeconds * 1_000_000_000)) }
            catch { return }
            await self?.interruptMimoCalibration(ids)
        }
        defer { timer.cancel(); for id in ids { mimoCalibration.requests.removeValue(forKey: id) } }
        return await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                for id in ids {
                    group.addTask { await self.runMimoCalibrationRequest(id, cell: cell, tokens: tokens) }
                }
                var success = true
                for await result in group { success = success && result }
                return success && !Task.isCancelled && !mimoCalibration.interrupted
            }
        } onCancel: {
            Task { await self.interruptMimoCalibration(ids) }
        }
    }

    private func runMimoCalibrationRequest(_ id: String, cell: MimoCalibrationPolicy.Cell,
        tokens: [Int]) async -> Bool {
        guard !Task.isCancelled else { return false }
        let request = ChatCompletionRequest(model: modelId, messages: [], temperature: 0,
            max_tokens: cell.outputTokens, seed: 42)
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

    func interruptMimoCalibration(_ ids: [String]) {
        // A delayed timer/cancellation callback cannot interrupt a later cell
        // or a replacement session after these exact requests have retired.
        guard ids.contains(where: { mimoCalibration.requests[$0] != nil }) else { return }
        mimoCalibration.interrupted = true
        for id in ids { cancel(requestId: id) }
    }
}
