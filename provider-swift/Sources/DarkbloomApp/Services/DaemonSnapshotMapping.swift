import Foundation
import ProviderCoreFoundation

/// Maps the daemon's on-disk truth (`~/.darkbloom/daemon-state.json` +
/// `local.json` + launchd install state) onto `ProviderSnapshot`, the model
/// every app surface already renders.
///
/// Pure and static so the whole mapping is testable without a daemon: the
/// service layer (see `DaemonRuntimeService`) only does file IO.
enum DaemonSnapshotMapping {
    struct Inputs {
        var state: DaemonState?
        var processIsAlive: Bool
        var serviceIsLoaded: Bool
        var localEndpoint: LocalEndpointInfo?
        var now: Date
        var providerName: String

        init(
            state: DaemonState?,
            processIsAlive: Bool,
            serviceIsLoaded: Bool = true,
            localEndpoint: LocalEndpointInfo?,
            now: Date = .now,
            providerName: String = "This Mac"
        ) {
            self.state = state
            self.processIsAlive = processIsAlive
            self.serviceIsLoaded = serviceIsLoaded
            self.localEndpoint = localEndpoint
            self.now = now
            self.providerName = providerName
        }
    }

    /// Trust statuses the coordinator sends that mean "not earning / gated",
    /// mirrored from ProviderCore's `TrustReasonCatalog` (keep aligned with
    /// `status == "untrusted" || status == "offline"` there).
    private static let failingTrustStatuses: Set<String> = ["untrusted", "offline", "denied", "failed"]

    /// A fresh model-load error demands attention; an old one is history.
    private static let loadErrorAttentionAge: TimeInterval = 300

    static func map(_ inputs: Inputs) -> ProviderSnapshot {
        let now = inputs.now
        let epochNow = now.timeIntervalSince1970
        let state = inputs.state
        let isRunning = state != nil && inputs.processIsAlive

        let runState = resolveRunState(inputs: inputs)
        let isFresh = (state.map { !$0.isStale(now: epochNow) } ?? false)
            && runState != .stale

        // Both timestamps track the SOURCE file, not the sampling clock. The
        // service polls on a fixed tick and publishes on Equatable change —
        // using `now` here would manufacture a diff on every tick (and a
        // redrawing UI) even when nothing changed. Wall-clock time only
        // enters through staleness/attention math, so the 90 s stale cutover
        // and fresh load-error attention still publish exactly once each.
        let sourceUpdatedAt = state.map { Date(timeIntervalSince1970: $0.writtenAt) } ?? .distantPast

        return ProviderSnapshot(
            sampledAt: sourceUpdatedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            runState: runState,
            providerName: inputs.providerName,
            version: state?.version ?? "unknown",
            pid: isRunning ? state?.pid : nil,
            startedAt: isRunning ? state.map { Date(timeIntervalSince1970: $0.startedAt) } : nil,
            trust: mapTrust(state?.trust),
            availability: mapAvailability(
                state: state,
                runState: runState,
                now: epochNow
            ),
            activity: ProviderActivitySnapshot(
                requestsServed: state?.stats.requestsServed ?? 0,
                tokensGenerated: state?.stats.tokensGenerated ?? 0,
                usageGaps: state?.stats.usageGaps ?? 0
            ),
            capacity: isRunning && isFresh ? state?.capacity.map(mapCapacity) : nil,
            currentModel: isRunning && isFresh ? state?.currentModel.map(modelSummary) : nil,
            warmModels: isRunning && isFresh ? (state?.warmModels ?? []).map(modelSummary) : [],
            lastProblem: resolveProblem(inputs: inputs, runState: runState),
            localEndpoint: mapLocalEndpoint(inputs: inputs, isRunning: isRunning, isFresh: isFresh),
            connectivity: state?.connectivity.map {
                ProviderConnectivitySnapshot(reconnectCount: $0.reconnectCount, lastError: $0.lastError)
            },
            system: isRunning && isFresh ? state?.system.map {
                ProviderSystemSnapshot(memoryPressure: $0.memoryPressure, cpuUsage: $0.cpuUsage, thermalState: $0.thermalState)
            } : nil
        )
    }

    // MARK: - Pieces

    private enum ScheduleState {
        case unreported
        case always
        case active(DaemonState.SchedulePosture)
        case off(DaemonState.SchedulePosture)
        case expired
        case unknown
    }

    private static func resolveRunState(inputs: Inputs) -> ProviderRunState {
        guard let state = inputs.state else {
            return .paused
        }
        let now = inputs.now.timeIntervalSince1970
        let scheduleState = classifySchedule(state.schedule, state: state, now: now)

        guard inputs.processIsAlive else {
            if inputs.serviceIsLoaded {
                switch scheduleState {
                case .off: return .scheduledOff
                case .unreported, .always, .active, .expired, .unknown:
                    return .stale
                }
            }
            return .paused
        }
        if case .expired = scheduleState {
            return .stale
        }
        if case .off = scheduleState {
            return .scheduledOff
        }
        if state.isStale(now: now) {
            return .stale
        }
        if state.inferenceActive {
            return .serving
        }
        if let trust = state.trust,
           failingTrustStatuses.contains(trust.status.lowercased()) {
            return .attention
        }
        if attentiveLoadError(inputs) != nil {
            return .attention
        }
        return .online
    }

    private static func mapAvailability(
        state: DaemonState?,
        runState: ProviderRunState,
        now: TimeInterval
    ) -> ProviderAvailabilitySnapshot {
        if runState == .paused {
            return ProviderAvailabilitySnapshot(
                state: .paused,
                summary: "Paused by you",
                nextChangeAt: nil
            )
        }

        guard let state, let schedule = state.schedule else {
            return ProviderAvailabilitySnapshot(
                state: .alwaysAvailable,
                summary: "Available whenever Darkbloom is running",
                nextChangeAt: nil
            )
        }

        let nextChange = schedule.nextChangeAtEpoch.map {
            Date(timeIntervalSince1970: $0)
        }
        switch classifySchedule(schedule, state: state, now: now) {
        case .active:
            return ProviderAvailabilitySnapshot(
                state: .scheduledActive,
                summary: schedule.summary,
                nextChangeAt: nextChange
            )
        case .off:
            return ProviderAvailabilitySnapshot(
                state: .scheduledOff,
                summary: "Outside scheduled hours · \(schedule.summary)",
                nextChangeAt: nextChange
            )
        case .expired, .unknown:
            return ProviderAvailabilitySnapshot(
                state: .unknown,
                summary: "Schedule state is waiting for a fresh provider update",
                nextChangeAt: nil
            )
        case .always, .unreported:
            return ProviderAvailabilitySnapshot(
                state: .alwaysAvailable,
                summary: "Available whenever Darkbloom is running",
                nextChangeAt: nil
            )
        }
    }

    private static func classifySchedule(
        _ schedule: DaemonState.SchedulePosture?,
        state: DaemonState,
        now: TimeInterval
    ) -> ScheduleState {
        guard let schedule else { return .unreported }
        switch schedule.mode.lowercased() {
        case "always":
            return .always
        case "scheduled-active":
            guard scheduleBoundaryIsCurrent(schedule, state: state, now: now) else {
                return .expired
            }
            return .active(schedule)
        case "scheduled-off":
            guard scheduleBoundaryIsCurrent(schedule, state: state, now: now) else {
                return .expired
            }
            return .off(schedule)
        default:
            return .unknown
        }
    }

    private static func scheduleBoundaryIsCurrent(
        _ schedule: DaemonState.SchedulePosture,
        state: DaemonState,
        now: TimeInterval
    ) -> Bool {
        if let nextChange = schedule.nextChangeAtEpoch {
            return now < nextChange
        }
        return !state.isStale(now: now)
    }

    private static func mapTrust(_ trust: DaemonState.Trust?) -> ProviderTrustSnapshot {
        guard let trust else {
            return ProviderTrustSnapshot(
                state: .unknown,
                level: "Not reported",
                reason: "The provider has not received a trust status from the network yet.",
                guidance: nil,
                updatedAt: nil
            )
        }
        let state: ProviderTrustState = switch OnboardingTrustGating.verdict(for: trust) {
        case .verified: .verified
        case .refused, .offline: .failed
        case .pending: .pending
        }
        return ProviderTrustSnapshot(
            state: state,
            level: trust.trustLevel.isEmpty ? "Unknown" : trust.trustLevel,
            reason: trust.reason.isEmpty ? "No reason reported." : trust.reason,
            guidance: nil,
            updatedAt: Date(timeIntervalSince1970: trust.receivedAt)
        )
    }

    private static func resolveProblem(inputs: Inputs, runState: ProviderRunState) -> ProviderProblem? {
        if runState == .stale {
            return ProviderProblem(
                id: "provider-state-stale",
                severity: .critical,
                title: "Darkbloom stopped checking in",
                detail: "The provider process may be asleep or unresponsive.",
                recoveryTitle: "Restart Darkbloom"
            )
        }
        if let loadError = attentiveLoadError(inputs),
           runState != .paused {
            return ProviderProblem(
                id: "model-load-error",
                severity: .warning,
                title: "A model failed to load",
                detail: "\(loadError.model): \(loadError.message)",
                recoveryTitle: "Review Mac"
            )
        }
        return nil
    }

    private static func attentiveLoadError(_ inputs: Inputs) -> DaemonState.ModelLoadError? {
        guard let loadError = inputs.state?.lastModelLoadError else {
            return nil
        }
        let age = max(0, inputs.now.timeIntervalSince1970 - loadError.at)
        return age < loadErrorAttentionAge ? loadError : nil
    }

    private static func mapCapacity(_ capacity: DaemonState.Capacity) -> ProviderCapacitySnapshot {
        ProviderCapacitySnapshot(
            totalMemoryGB: capacity.totalMemoryGb,
            gpuMemoryActiveGB: capacity.gpuMemoryActiveGb,
            gpuMemoryCacheGB: capacity.gpuMemoryCacheGb
        )
    }

    private static func mapLocalEndpoint(
        inputs: Inputs,
        isRunning: Bool,
        isFresh: Bool
    ) -> ProviderLocalEndpointSnapshot? {
        guard isRunning, let info = inputs.localEndpoint,
           let baseURL = URL(string: info.baseURL)
        else {
            return nil
        }
        return ProviderLocalEndpointSnapshot(
            baseURL: baseURL,
            requiresAuthentication: !info.apiKey.isEmpty,
            isReachable: isFresh
        )
    }

    /// "gemma-4-26b-qat-4bit" → "Gemma 4 26B QAT 4-bit"; ids are the truth,
    /// display names are a courtesy (the registry's canonical name arrives
    /// with the model-library slice).
    static func modelSummary(id: String) -> ProviderModelSummary {
        ProviderModelSummary(
            id: id,
            displayName: modelDisplayName(id),
            sizeGB: nil,
            isVision: id.localizedCaseInsensitiveContains("-vl-")
                || id.localizedCaseInsensitiveContains("vision")
        )
    }

    static func modelDisplayName(_ id: String) -> String {
        let shoutyTokens: [String: String] = [
            "gpt": "GPT", "oss": "OSS", "qat": "QAT", "vl": "VL",
            "mtp": "MTP", "l3": "L3", "it": "Instruct",
        ]
        let words = id.split(separator: "-").map { token -> String in
            let token = String(token)
            if let shout = shoutyTokens[token.lowercased()] { return shout }
            if token.range(of: #"^\d+b$"#, options: .regularExpression) != nil {
                return token.uppercased()
            }
            if token.range(of: #"^\d+bit$"#, options: .regularExpression) != nil {
                return token.replacingOccurrences(of: "bit", with: "-bit")
            }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        return words.joined(separator: " ")
    }
}
