import Foundation

/// ProviderLoop -- selected models recover their residency.
///
/// A selected model the startup preload skipped for memory or a slot, or that
/// an Autopilot operation unloaded to load another model, stayed cold until a
/// request loaded it, and the coordinator cold-routes a model only to an idle
/// machine, so behind a busy model outside the selection it never loaded:
/// nothing retried it. Each such model now waits in `selectedModelRecovery`,
/// and the capacity tick checks it when due (backoff from 30 s to 10 min; an
/// unload makes it due at once). A check loads it without evicting: before
/// the load it may unload only models outside the selection that no request
/// could load back, that serve no request and hold no placement or pin, that
/// meet Autopilot's own victim rules (`selectedModelRecoveryVictimWait`), and
/// whose memory makes the room. It never evicts a selected model, so a
/// recovered model is never displaced by another recovery. While a live
/// Autopilot lease manages residency, recovery waits.
extension ProviderLoop {
    /// The startup preload's candidates it left cold for memory or a slot
    /// join the recovery (`finishStartupPreload`), as do the selected victims
    /// of an Autopilot operation (`noteSelectedModelUnloaded`).
    func enqueueSelectedModelRecovery(_ ids: [String]) {
        let now = ContinuousClock.now
        let nowEpoch = Date().timeIntervalSince1970
        for id in ids where modelSlots[id] == nil && selectedModelRecoveryApplies(id) {
            selectedModelRecovery.enqueue(id, now: now, nowEpoch: nowEpoch)
            logger.info("Selected model \(id) is not resident; retrying when memory frees")
        }
    }

    /// Explicitly selected (not just on disk), in the ordinary selection,
    /// advertised, eligible and not fenced. A model the saved filter dropped
    /// after the start leaves the recovery even though the running daemon
    /// still advertises it.
    private func selectedModelRecoveryApplies(_ id: String) -> Bool {
        let saved = savedEnabledModels
        if !saved.isEmpty, saved != loopConfig.config.backend.enabledModels, !saved.contains(id) { return false }
        return explicitlySelectedModelIDs.contains(id)
            && ordinaryServingModelIDs.contains(id) && advertisedModels[id] != nil
            && failedSelfTestHashes[id] == nil && !isRefusedByRetirement(id)
            && ModelRuntimeRequirements.isEligible(modelID: id, available: loopConfig.runtimeCapabilities)
    }

    /// The operator's explicit choices at start: `enabled_models`,
    /// `preload_models`, the pinned `model` and Autopilot's persisted
    /// selection. Without any, every model on disk is served and a cold one
    /// loads on request, so nothing is retried.
    private var explicitlySelectedModelIDs: Set<String> {
        let backend = loopConfig.config.backend
        var ids = Set(backend.enabledModels).union(backend.preloadModels)
        if let pin = backend.model, !pin.isEmpty { ids.insert(pin) }
        if autopilotConsented { ids.formUnion(autopilotSettings.selectedModels) }
        return ids
    }

    /// Drops entries that loaded by other means or no longer apply.
    private func pruneSelectedModelRecovery() {
        for id in selectedModelRecovery.entries.keys where selectedModelRecovery.attempt?.model != id
            && (modelSlots[id] != nil || !selectedModelRecoveryApplies(id)) {
            selectedModelRecovery.remove(id)
        }
    }

    /// An operation's victim waits for memory from the moment it leaves
    /// residency, whether the operation then succeeds or fails, and whatever
    /// its target. An unload-only operation removes models on purpose: it
    /// queues nothing. Only models the recovery applies to join.
    func noteSelectedModelUnloaded(_ id: String, by command: ModelAutopilotCommand) {
        guard command.loadModelId != nil else { return }
        enqueueSelectedModelRecovery([id])
    }

    /// Models a recovery never evicts: the ordinary selection, Autopilot
    /// pins, and any advertised model a request could load straight back
    /// (`autopilotAllowsModel`, such as inventory published under a live
    /// lease), which would then evict the recovered model in turn. An
    /// adoption ends with its residency, so an adopted model is no exception.
    func isProtectedFromRecoveryEviction(_ id: String) -> Bool {
        ordinaryServingModelIDs.contains(id) || autopilotPinnedModels.contains(id)
            || (advertisedModels[id] != nil && autopilotAllowsModel(id))
    }

    /// Autopilot's own victim rules (`ModelAutopilotPolicy`) for a model that
    /// still serves: resident `min_dwell_seconds`, no unexpired per-model
    /// lease, and idle, from its last request or its hold's expiry
    /// (`autopilotIdleSince`), for the longer of `victimMinimumIdle` and
    /// `min_idle_seconds`. Returns what is unmet and when all of it will be;
    /// nil when the rules let recovery evict it now.
    func selectedModelRecoveryVictimWait(_ id: String, slot: ModelSlot, now: ContinuousClock.Instant)
        -> (reasons: [String], until: ContinuousClock.Instant)? {
        let settings = autopilotSettings
        var reasons: [String] = []
        var until = now
        let dwell = Duration.seconds(settings.effectiveMinDwellSeconds)
        let residentSince = autopilotResidentSince[id] ?? now
        if now - residentSince < dwell {
            reasons.append("resident \(Self.recoverySeconds(now - residentSince)) of Autopilot's "
                + "\(Self.recoverySeconds(dwell)) minimum dwell")
            until = max(until, residentSince.advanced(by: dwell))
        }
        if let lease = autopilotLeaseUntil[id], now < lease {
            reasons.append("Autopilot lease for another \(Self.recoverySeconds(now.duration(to: lease)))")
            until = max(until, lease)
        }
        let minimumIdle = max(SelectedModelRecovery.victimMinimumIdle, .seconds(settings.effectiveMinIdleSeconds))
        let idleSince = autopilotIdleSince(id, lastInferenceAt: slot.lastInferenceAt)
        if now - idleSince < minimumIdle {
            reasons.append("idle \(Self.recoverySeconds(now - idleSince)) of the "
                + "\(Self.recoverySeconds(minimumIdle)) recovery waits for")
            until = max(until, idleSince.advanced(by: minimumIdle))
        }
        return reasons.isEmpty ? nil : (reasons, until)
    }

    /// The plan's verdict on one victim, rechecked right before its unload
    /// against the plan's own instant: residency control or the victim's
    /// state may have changed in between (a lease can begin, a request can
    /// come and go).
    private func selectedModelRecoveryMayStillEvict(_ id: String, plannedAt: ContinuousClock.Instant) -> Bool {
        guard let slot = modelSlots[id], !isProtectedFromRecoveryEviction(id),
              evictionExclusions(now: plannedAt)[id] == nil else { return false }
        return !autopilotServesModel(id) || selectedModelRecoveryVictimWait(id, slot: slot, now: plannedAt) == nil
    }

    /// Run on every capacity tick: starts one attempt when an entry is due.
    func checkSelectedModelRecoveryIfDue(now: ContinuousClock.Instant = .now) async {
        pruneSelectedModelRecovery()
        guard selectedModelRecovery.attempt == nil, !isShuttingDown,
              let target = selectedModelRecovery.nextDue(now: now) else { return }
        if let reason = selectedModelRecoveryPauseReason() {
            selectedModelRecovery.pause(target, blocker: reason, now: now)
            return
        }
        switch await selectedModelRecoveryPlan(for: target, now: now) {
        case .blocked(let blocker, let retryAt):
            selectedModelRecovery.deferCheck(target, blocker: blocker, now: now, retryAt: retryAt)
        case .load(let victims):
            // The sample above suspended: recheck before taking ownership.
            guard selectedModelRecovery.attempt == nil, selectedModelRecoveryPauseReason() == nil,
                  selectedModelRecovery.entries[target] != nil else { return }
            let task = Task { await self.attemptSelectedModelRecovery(target, evicting: victims, plannedAt: now) }
            selectedModelRecovery.attempt = (target, task)
        case .releaseAdoption(let id):
            guard selectedModelRecovery.attempt == nil, selectedModelRecoveryPauseReason() == nil else { return }
            let blocker = await releaseAdoptionForSelectedModelRecovery(id, target: target)
            selectedModelRecovery.pause(target, blocker: blocker, now: now)
        }
    }

    /// Residency is changing for another reason, or Autopilot owns it.
    private func selectedModelRecoveryPauseReason() -> String? {
        if servingDrain.refusing || updatePhase != .idle || isReconnectingAfterRetirement {
            return "the provider is draining"
        }
        if autopilotManagesResidency { return "Autopilot manages residency under its live lease" }
        if autopilotCommand != nil { return "an Autopilot operation is in progress" }
        if modelSwitchTask != nil { return "a model switch is in progress" }
        if startupPreloadTask != nil { return "the startup preload is still running" }
        if isLoadingAny || !modelsLoading.isEmpty || !modelsUnloading.isEmpty || modelRevisionActivationID != nil {
            return "another model load or unload is in progress"
        }
        return nil
    }

    enum SelectedModelRecoveryPlan: Equatable {
        /// Load after unloading these idle unselected models, in order.
        case load(evicting: [String])
        /// End this busy adoption so it drains (`adoptionReleaseTime`).
        case releaseAdoption(String)
        case blocked(String, retryAt: ContinuousClock.Instant?)
    }

    /// Whether `target` fits now or after evicting the shortest
    /// least-recently-used run of idle unselected models, on the gate's own
    /// figures; else what keeps it out and when that may change.
    func selectedModelRecoveryPlan(for target: String, now: ContinuousClock.Instant) async -> SelectedModelRecoveryPlan {
        guard let info = advertisedModels[target] else { return .blocked("not advertised", retryAt: nil) }
        let exclusions = evictionExclusions(now: now)
        var victims: [(id: String, bytes: UInt64)] = []
        var releasable: [(id: String, bytes: UInt64, at: ContinuousClock.Instant)] = []
        var waits: [String] = []
        var retryAt: ContinuousClock.Instant?
        let outside = modelSlots.filter { $0.key != target && !isProtectedFromRecoveryEviction($0.key) }
            .sorted { ($0.value.lastInferenceAt, $0.key) < ($1.value.lastInferenceAt, $1.key) }
        for (id, slot) in outside {
            if let reasons = exclusions[id] {
                waits.append(contentsOf: evictionExclusionRecords([id: reasons]).map(\.summary))
                if let hold = autopilotHolds[id], autopilotHoldsModel(id, now: now) {
                    retryAt = Self.earlier(retryAt, hold.until.advanced(by: SelectedModelRecovery.victimMinimumIdle))
                }
                if let since = selectedModelRecovery.entries[target]?.since,
                   let at = adoptionReleaseTime(id, reasons: reasons, waitingSince: since, now: now) {
                    releasable.append((id, UInt64(max(0, slot.sizing.weightsBytes)), at))
                }
                continue
            }
            // A model nothing serves any more takes no new request: it waits
            // for none of the victim rules.
            if autopilotServesModel(id), let wait = selectedModelRecoveryVictimWait(id, slot: slot, now: now) {
                waits.append("\(id) (\(wait.reasons.joined(separator: "; ")))")
                retryAt = Self.earlier(retryAt, wait.until)
                continue
            }
            victims.append((id, UInt64(max(0, slot.sizing.weightsBytes))))
        }

        let room = await selectedModelRecoveryRoom(for: info)
        let slotsToFree = max(0, modelSlots.count + 1 - maxModelSlots)
        var reclaimed: UInt64 = 0
        for count in 0...victims.count {
            if count > 0 {
                let (sum, overflow) = reclaimed.addingReportingOverflow(victims[count - 1].bytes)
                reclaimed = overflow ? .max : sum
            }
            if count >= slotsToFree, room.fits(reclaimed) {
                return .load(evicting: victims.prefix(count).map(\.id))
            }
        }
        // Busy adoptions whose release, once they drain, makes the room.
        var withReleased = reclaimed
        for count in releasable.indices.map({ $0 + 1 }) {
            let (sum, overflow) = withReleased.addingReportingOverflow(releasable[count - 1].bytes)
            withReleased = overflow ? .max : sum
            guard victims.count + count >= slotsToFree, room.fits(withReleased) else { continue }
            let drained = releasable.prefix(count)
            if let due = drained.first(where: { $0.at <= now }) { return .releaseAdoption(due.id) }
            retryAt = Self.earlier(retryAt, drained.map(\.at).min() ?? now)
            break
        }
        var blocker = "needs \(Self.recoveryGb(room.requiredBytes)) GB; \(Self.recoveryGb(room.usableBytes)) GB usable"
        if slotsToFree > victims.count { blocker += "; all \(maxModelSlots) model slot(s) are in use" }
        if !waits.isEmpty { blocker += "; waiting for " + waits.joined(separator: ", ") }
        let stale = modelSlots.keys.filter { id in
            !savedEnabledModels.isEmpty && ordinaryServingModelIDs.contains(id) && !savedEnabledModels.contains(id)
        }.sorted()
        if !stale.isEmpty {
            blocker += "; \(stale.joined(separator: ", ")) stays in the running daemon's selection until a restart applies the saved enabled_models"
        } else if waits.isEmpty {
            blocker += "; no model outside the selection can be evicted to make room"
        }
        return .blocked(blocker, retryAt: retryAt)
    }

    /// The load gate's room and requirement for `info`: Super's LOAD claim
    /// against its narrowest configuration, otherwise usable load memory
    /// against the weights plus the serving-set headroom.
    private func selectedModelRecoveryRoom(for info: ModelInfo) async -> SelectedModelRecoveryRoom {
        if isNemotronSuperIdentity(info.id) {
            return .init(usableBytes: nemotronSuperClaimRoomBytes(),
                         requiredBytes: nemotronSuperLoadRequirements(info).last ?? .max)
        }
        let available = await availableMemoryGb()
        let required = ModelLoadAdmission.requiredToLoadGb(weightsGb: info.estimatedMemoryGb, headroomGb: loadHeadroomGb)
        return .init(usableBytes: Self.recoveryBytes(available), requiredBytes: Self.recoveryBytes(required))
    }

    /// Evicts the planned victims, each rechecked against the plan's rules
    /// and then by the eviction gate, and loads the target without eviction.
    /// A victim that no longer qualifies ends the attempt before any further
    /// unload; the next check plans again. A refusal for memory, a slot or a
    /// transient state keeps the target waiting; any other failure ends its
    /// recovery (the request path still loads it on demand).
    private func attemptSelectedModelRecovery(_ target: String, evicting victims: [String],
                                              plannedAt: ContinuousClock.Instant) async {
        defer {
            selectedModelRecovery.attempt = nil
            writeDaemonState()
        }
        writeDaemonState()
        for victim in victims {
            guard !Task.isCancelled, !isShuttingDown else { return }
            if let reason = selectedModelRecoveryPauseReason() {
                selectedModelRecovery.pause(target, blocker: reason, now: .now)
                return
            }
            guard selectedModelRecoveryMayStillEvict(victim, plannedAt: plannedAt) else {
                selectedModelRecovery.pause(target, blocker: "\(victim) changed before it could be evicted", now: .now)
                return
            }
            logger.info("Selected-model recovery: evicting idle \(victim) (outside the selection) to load \(target)")
            guard await unloadModel(victim, forEviction: true) else {
                selectedModelRecovery.deferCheck(target, blocker: "\(victim) became busy before it could be evicted",
                    now: .now)
                return
            }
        }
        guard !Task.isCancelled, !isShuttingDown else { return }
        do {
            if let override = selectedModelRecoveryLoadOverride {
                try await override(target)
            } else {
                try await ensureModelLoaded(modelId: target, allowEviction: false)
            }
            selectedModelRecovery.remove(target)
            logger.info("Selected-model recovery: \(target) is resident again")
            await updateAggregateCapacity()
            await coordinatorClient?.sendEventHeartbeat()
        } catch is CancellationError {
            return
        } catch {
            let message = Self.recoveryFailureText(error)
            if Self.recoveryMayRetry(error) {
                selectedModelRecovery.deferCheck(target, blocker: message, now: .now)
            } else {
                selectedModelRecovery.remove(target)
                logger.warning("Selected-model recovery: \(target) failed to load; it loads on request instead: \(message)")
            }
        }
    }

    /// Refusals that a later check can clear: memory, a slot, or a
    /// transition in progress.
    static func recoveryMayRetry(_ error: any Error) -> Bool {
        if StartupPreloader.isInsufficientMemoryLoad(error) { return true }
        switch error as? InferenceError {
        case .modelLoadFailed(let message)?, .invalidModelDirectory(let message)?:
            return message.contains("model slot") || message.hasPrefix("Insufficient memory")
                || message.contains("is being downloaded or verified") || message == "provider_draining"
                || message == "model autopilot placement in progress"
        default:
            return false
        }
    }

    /// `InferenceError` has no localized description; its message is the text.
    private static func recoveryFailureText(_ error: any Error) -> String {
        switch error as? InferenceError {
        case .modelLoadFailed(let message)?, .invalidModelDirectory(let message)?, .generationFailed(let message)?:
            return message
        default:
            return String(describing: error)
        }
    }

    /// The daemon-state report, waiting longest first.
    func selectedModelRecoveryReport(now: ContinuousClock.Instant = .now,
                                     nowEpoch: Double = Date().timeIntervalSince1970)
        -> [DaemonState.SelectedModelRecoveryEntry]? {
        guard !selectedModelRecovery.isEmpty else { return nil }
        return selectedModelRecovery.entries.sorted { ($0.value.since, $0.key) < ($1.value.since, $1.key) }
            .map { id, entry in
                let loading = selectedModelRecovery.attempt?.model == id
                let untilNext = now.duration(to: entry.nextCheckAt)
                return .init(model: id, waitingSince: entry.sinceEpoch,
                    nextCheckAt: loading ? nil : nowEpoch + max(0, Self.recoverySecondsValue(untilNext)),
                    checks: entry.checks, blocker: entry.blocker, loading: loading ? true : nil)
            }
    }

    private static func earlier(_ a: ContinuousClock.Instant?, _ b: ContinuousClock.Instant) -> ContinuousClock.Instant {
        a.map { min($0, b) } ?? b
    }

    private static func recoverySecondsValue(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func recoverySeconds(_ duration: Duration) -> String {
        DurationFormatting.compact(max(0, recoverySecondsValue(duration)), spaced: false)
    }

    private static func recoveryGb(_ bytes: UInt64) -> String {
        bytes == .max ? "∞" : String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    private static func recoveryBytes(_ gb: Double) -> UInt64 {
        guard gb.isFinite, gb > 0 else { return 0 }
        let bytes = gb * 1_073_741_824
        return bytes >= Double(UInt64.max) ? .max : UInt64(bytes)
    }
}

/// What a recovery load needs and what the gate has, before evictions.
struct SelectedModelRecoveryRoom: Equatable {
    let usableBytes: UInt64
    let requiredBytes: UInt64

    func fits(_ reclaimedBytes: UInt64) -> Bool {
        let (reachable, overflow) = usableBytes.addingReportingOverflow(reclaimedBytes)
        return overflow || reachable >= requiredBytes
    }
}
