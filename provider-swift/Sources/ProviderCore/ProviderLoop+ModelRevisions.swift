import Foundation

/// Declarative reconciliation is keyed by artifact identity, not model ID alone.
/// One background worker bounds disk/network pressure; failed attempts retry
/// indefinitely with a capped, jittered backoff while the old revision serves.
extension ProviderLoop {
    func updateDesiredModelRevisions(_ entries: [CoordinatorMessage.DesiredModelEntry]) {
        var wanted: [String: CoordinatorMessage.DesiredModelEntry] = [:]
        for entry in entries where entry.revision?.isEmpty == false && entry.aggregateSHA256?.isEmpty == false {
            guard desiredPrefetchTargets.contains(entry.desiredBuild) else { continue }
            // Several public aliases can name one artifact. Alias labels and
            // lineage changes do not cancel an otherwise identical download.
            wanted[entry.desiredBuild] = .init(modelName: entry.desiredBuild,
                desiredBuild: entry.desiredBuild, revision: entry.revision,
                aggregateSHA256: entry.aggregateSHA256)
        }
        desiredModelRevisions = wanted
        if let attempt = modelRevisionAttempt, wanted[attempt.entry.desiredBuild] != attempt.entry {
            attempt.task.cancel()
        }
    }

    func startModelRevisionMonitor() {
        guard modelRevisionMonitorTask == nil else { return }
        modelRevisionMonitorTask = Task { [weak self] in
            var nextAttempt: [String: ContinuousClock.Instant] = [:]
            var lastIdentity: [String: CoordinatorMessage.DesiredModelEntry] = [:]
            var failures: [String: Int] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                let entries = await self.pendingModelRevisions()
                let pending = Set(entries.map(\.desiredBuild))
                nextAttempt = nextAttempt.filter { pending.contains($0.key) }
                lastIdentity = lastIdentity.filter { pending.contains($0.key) }
                failures = failures.filter { pending.contains($0.key) }
                for entry in entries where !Task.isCancelled {
                    let id = entry.desiredBuild
                    if lastIdentity[id] != entry { nextAttempt[id] = nil; failures[id] = 0 }
                    lastIdentity[id] = entry
                    if let next = nextAttempt[id], .now < next { continue }
                    await self.runModelRevisionAttempt(entry)
                    failures[id, default: 0] += 1
                    let cap = min(300, 15 * (1 << min(failures[id, default: 0] - 1, 5)))
                    nextAttempt[id] = .now.advanced(by: .seconds(Int.random(in: max(1, cap / 2)...cap)))
                }
                do { try await taskSleep(.seconds(5)) } catch { return }
            }
        }
    }

    func pendingModelRevisions() -> [CoordinatorMessage.DesiredModelEntry] {
        guard !isShuttingDown, !state.refusingNewWork else { return [] }
        return desiredModelRevisions.values.filter {
            liveModelHashes[$0.desiredBuild] != $0.aggregateSHA256 || advertisedModels[$0.desiredBuild] == nil || failedModelRevisionRestores[$0.desiredBuild] != nil
        }.sorted { $0.desiredBuild < $1.desiredBuild }
    }

    func revisionIsDesired(_ entry: CoordinatorMessage.DesiredModelEntry) -> Bool {
        !isShuttingDown && !state.refusingNewWork && desiredModelRevisions[entry.desiredBuild] == entry
    }

    private func runModelRevisionAttempt(_ entry: CoordinatorMessage.DesiredModelEntry) async {
        guard revisionIsDesired(entry) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome = await ModelIdleUpgrade.run(
                prepare: { try await self.prepareModelRevision(entry) },
                waitBeforeDrain: { try await self.waitBeforeModelUpgradeDrain(entry.desiredBuild) },
                beginDrain: { try await self.beginModelRevisionDrain($0) },
                commitIfIdle: { try await self.commitModelRevisionIfIdle($0) },
                discard: { $0.lease.release() },
                finishDrain: { await self.finishModelRevisionDrain($0) })
            await self.logModelRevisionOutcome(entry, outcome: outcome)
        }
        modelRevisionAttempt = (entry, task)
        await task.value
        modelRevisionAttempt = nil
    }

    private func logModelRevisionOutcome(_ entry: CoordinatorMessage.DesiredModelEntry, outcome: ModelIdleUpgrade.Outcome) {
        logger.info("model revision: model=\(entry.desiredBuild) revision=\(entry.revision ?? "") outcome=\(outcome)")
        if outcome != .installed {
            outboundSend?.send(.prefetchModelStatus(modelId: entry.desiredBuild, status: .failed,
                bytesDone: 0, bytesTotal: 0, error: "revision activation \(outcome); reconciliation will retry if still desired"))
        }
    }

    func prepareModelRevision(_ entry: CoordinatorMessage.DesiredModelEntry) async throws -> StagedModelRevision? {
        guard revisionIsDesired(entry) else { return nil }
        if let active = ModelScanner.resolveLocalPath(modelID: entry.desiredBuild) {
            let managed = ModelDownloader.cacheModelDirectory(for: entry.desiredBuild)
                .appendingPathComponent("snapshots", isDirectory: true).resolvingSymlinksInPath()
            guard active.deletingLastPathComponent().standardizedFileURL == managed.standardizedFileURL else {
                throw ModelCatalogError.downloadFailed("automatic revisions cannot replace an external snapshot override")
            }
        }
        let client = ModelCatalogClient(coordinatorURL: loopConfig.coordinatorURL)
        let catalog = try await client.fetchCatalog()
        guard let model = catalog.first(where: { $0.id == entry.desiredBuild }),
            model.version == entry.revision, model.aggregateSHA256 == entry.aggregateSHA256
        else { return nil } // A newer promotion raced this desired-state frame.
        let downloader = ModelDownloader(catalogClient: client, concurrency: 1,
            runtimeCapabilities: loopConfig.runtimeCapabilities)
        let manifest = try await downloader.resolveManifest(model: model)
        let send = outboundSend
        send?.send(.prefetchModelStatus(modelId: model.id, status: .started, bytesDone: 0,
            bytesTotal: manifest.totalSizeBytes, error: nil))
        do {
            let directory = try await downloader.prefetch(model: model, manifest: manifest,
                onByteProgress: { done, total in
                    send?.send(.prefetchModelStatus(modelId: model.id, status: .downloading,
                        bytesDone: done, bytesTotal: total, error: nil))
                }, activate: false)
            try Task.checkCancellation()
            guard revisionIsDesired(entry) else { return nil }
            let info = await Task.detached(priority: .utility) {
                ModelScanner.parseModelInfo(snapshotDir: directory, modelName: model.id)
            }.value
            guard var info, info.templateRenderOK != false, EngineV2SupportedModels.isSupported(model: info) else {
                throw ModelCatalogError.downloadFailed("revision failed engine/template compatibility checks")
            }
            info.weightHash = manifest.aggregateSHA256
            // Refresh auxiliary-artifact metadata as part of target revision
            // preparation. The existing MTP funnel still verifies and stages
            // assistants; an old cached catalog entry must not bind a stale one.
            _ = await specDecFunnel.prewarmCatalog(modelId: model.id,
                timeout: Self.specDecCatalogPrewarmTimeout, forceRefresh: true)
            let lease = try await ModelArtifactWriteLease.acquire(modelID: model.id)
            guard revisionIsDesired(entry), !Task.isCancelled else { lease.release(); return nil }
            return StagedModelRevision(entry: entry, directory: directory, info: info, lease: lease,
                totalSizeBytes: manifest.totalSizeBytes)
        } catch {
            send?.send(.prefetchModelStatus(modelId: model.id, status: .failed, bytesDone: 0,
                bytesTotal: manifest.totalSizeBytes, error: error.localizedDescription))
            throw error
        }
    }
}
