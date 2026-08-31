import Foundation

extension ProviderLoop {
    internal func handleLoadModelRequest(
        modelId: String,
        send: SendHandle
    ) {
        guard advertisedModels[modelId] != nil else {
            send.send(.loadModelStatus(
                modelId: modelId, status: .failed,
                error: "model is not advertised"))
            return
        }
        if preloadTasks[modelId] != nil {
            preloadStatusSubscribers[modelId, default: []].append(send)
            return
        }

        let taskID = UUID()
        preloadTaskIds[modelId] = taskID
        preloadStatusSubscribers[modelId] = [send]
        send.send(.loadModelStatus(
            modelId: modelId, status: .started, error: nil))
        preloadTaskStarted?(modelId)
        preloadTasks[modelId] = Task { [weak self] in
            guard let self else { return }
            let status: ProviderMessage.LoadModelStatus.Status
            let message: String?
            do {
                try await self.inferenceWorkerClient.preloadModel(
                    identifier: modelId)
                status = .succeeded
                message = nil
            } catch {
                status = .failed
                message = "worker rejected model preload"
            }
            await self.finishPreloadTask(
                modelId: modelId, taskId: taskID,
                status: status, error: message)
        }
    }

    private func finishPreloadTask(
        modelId: String,
        taskId: UUID,
        status: ProviderMessage.LoadModelStatus.Status,
        error: String?
    ) {
        guard preloadTaskIds[modelId] == taskId else { return }
        preloadTasks.removeValue(forKey: modelId)
        preloadTaskIds.removeValue(forKey: modelId)
        let subscribers =
            preloadStatusSubscribers.removeValue(forKey: modelId) ?? []
        for subscriber in subscribers {
            subscriber.send(.loadModelStatus(
                modelId: modelId, status: status, error: error))
        }
    }

    internal func waitForPreloads(
        _ preloads: [Task<Void, Never>],
        timeout: Duration
    ) async -> Bool {
        guard !preloads.isEmpty else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for task in preloads { await task.value }
                return true
            }
            group.addTask {
                do {
                    try await taskSleep(timeout)
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    internal func cancelLoadWaiters() {
        for task in preloadTasks.values { task.cancel() }
    }
}
