import Foundation

enum ProviderPreviewScenario: String, CaseIterable, Identifiable, Sendable {
    case online
    case serving
    case paused
    case scheduledActive = "scheduled-active"
    case scheduledOff = "scheduled-off"
    case pausedScheduled = "paused-scheduled"
    case attention
    case stale

    var id: String { rawValue }

    var snapshot: ProviderSnapshot {
        PreviewProviderRuntimeService.fixture(for: self)
    }

    var usesScheduledAvailability: Bool {
        switch self {
        case .scheduledActive, .scheduledOff, .pausedScheduled:
            true
        case .online, .serving, .paused, .attention, .stale:
            false
        }
    }
}

actor PreviewProviderRuntimeService: ProviderRuntimeServicing {
    private static let referenceDate = Date(timeIntervalSince1970: 1_784_308_800)
    private static let scheduledActiveReferenceDate = Date(timeIntervalSince1970: 1_784_352_000)
    private static let scheduledOffReferenceDate = Date(timeIntervalSince1970: 1_784_384_400)
    private static let defaultModel = ProviderModelSummary(
        id: "gpt-oss-20b",
        displayName: "GPT OSS 20B",
        sizeGB: 12.8,
        isVision: false
    )
    private static let secondModel = ProviderModelSummary(
        id: "gemma-4-26b-qat-4bit",
        displayName: "Gemma 4 26B",
        sizeGB: 15.8,
        isVision: false
    )

    private var snapshot: ProviderSnapshot
    private var usesScheduledAvailability: Bool
    private var sequence = 0
    private var continuations: [UUID: AsyncStream<ProviderSnapshot>.Continuation] = [:]
    private let transitionDelay: Duration

    init(
        scenario: ProviderPreviewScenario = .online,
        transitionDelay: Duration = .milliseconds(360)
    ) {
        snapshot = Self.fixture(for: scenario)
        usesScheduledAvailability = scenario.usesScheduledAvailability
        self.transitionDelay = transitionDelay
    }

    func currentSnapshot() -> ProviderSnapshot {
        snapshot
    }

    func updates() -> AsyncStream<ProviderSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ProviderSnapshot.self)

        continuations[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id)
            }
        }
        return stream
    }

    @discardableResult
    func perform(_ action: ProviderAction) async throws -> ProviderSnapshot {
        switch action {
        case .start:
            try await start()
        case .stop:
            try await stop()
        case .restart:
            try await restart()
        case .refresh, .runDiagnostics:
            touch(sourceDidUpdate: snapshot.runState != .stale)
            publish()
        }
        return snapshot
    }

    func setScenario(_ scenario: ProviderPreviewScenario) {
        snapshot = Self.fixture(for: scenario)
        usesScheduledAvailability = scenario.usesScheduledAvailability
        sequence = 0
        publish()
    }

    static func fixture(for scenario: ProviderPreviewScenario) -> ProviderSnapshot {
        let sampledAt: Date = switch scenario {
        case .scheduledActive, .pausedScheduled:
            scheduledActiveReferenceDate
        case .scheduledOff:
            scheduledOffReferenceDate
        case .online, .serving, .paused, .attention, .stale:
            referenceDate
        }
        let startedAt = sampledAt.addingTimeInterval(-12_840)
        let verifiedTrust = ProviderTrustSnapshot(
            state: .verified,
            level: "Hardware verified",
            reason: "Secure Enclave and MDM verification passed",
            guidance: nil,
            updatedAt: sampledAt.addingTimeInterval(-18)
        )
        let standardAvailability = ProviderAvailabilitySnapshot(
            state: .alwaysAvailable,
            summary: "Available whenever Darkbloom is running",
            nextChangeAt: nil
        )
        let standardActivity = ProviderActivitySnapshot(
            requestsServed: 1_284,
            tokensGenerated: 842_711,
            usageGaps: 0
        )
        let standardCapacity = ProviderCapacitySnapshot(
            totalMemoryGB: 128,
            gpuMemoryActiveGB: 21.6,
            gpuMemoryCacheGB: 3.2
        )
        let endpoint = ProviderLocalEndpointSnapshot(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            requiresAuthentication: true,
            isReachable: true
        )

        var result = ProviderSnapshot(
            sampledAt: sampledAt,
            sourceUpdatedAt: sampledAt,
            runState: .online,
            providerName: "Darkbloom Mac",
            version: "0.7.9",
            pid: 7_304,
            startedAt: startedAt,
            trust: verifiedTrust,
            availability: standardAvailability,
            activity: standardActivity,
            capacity: standardCapacity,
            currentModel: nil,
            warmModels: [defaultModel, secondModel],
            lastProblem: nil,
            localEndpoint: endpoint,
            connectivity: nil,
            system: nil
        )

        switch scenario {
        case .online:
            break
        case .serving:
            result.runState = .serving
            result.currentModel = defaultModel
            result.activity.requestsServed += 1
            result.activity.tokensGenerated += 614
            result.capacity?.gpuMemoryActiveGB = 34.8
        case .paused:
            result.runState = .paused
            result.pid = nil
            result.startedAt = nil
            result.availability = ProviderAvailabilitySnapshot(
                state: .paused,
                summary: "Paused by you",
                nextChangeAt: nil
            )
            result.capacity = nil
            result.warmModels = []
            result.localEndpoint = nil
        case .scheduledActive:
            result.availability = ProviderAvailabilitySnapshot(
                state: .scheduledActive,
                summary: "Weeknights, 8:00 PM–7:00 AM",
                nextChangeAt: sampledAt.addingTimeInterval(31_200)
            )
        case .scheduledOff:
            result.runState = .scheduledOff
            result.availability = ProviderAvailabilitySnapshot(
                state: .scheduledOff,
                summary: "Weekends, 9:00 AM–6:00 PM",
                nextChangeAt: sampledAt.addingTimeInterval(6_000)
            )
            result.currentModel = nil
            result.warmModels = []
            result.capacity?.gpuMemoryActiveGB = 0.8
            result.localEndpoint = nil
        case .pausedScheduled:
            result.runState = .paused
            result.pid = nil
            result.startedAt = nil
            result.availability = ProviderAvailabilitySnapshot(
                state: .paused,
                summary: "Paused by you · schedule retained",
                nextChangeAt: sampledAt.addingTimeInterval(31_200)
            )
            result.capacity = nil
            result.warmModels = []
            result.localEndpoint = nil
        case .attention:
            result.runState = .attention
            result.trust = ProviderTrustSnapshot(
                state: .pending,
                level: "Secure Enclave verified",
                reason: "Awaiting MDM verification",
                guidance: "Finish verification in System Settings, then run diagnostics again.",
                updatedAt: sampledAt.addingTimeInterval(-44)
            )
            result.lastProblem = ProviderProblem(
                id: "hardware-trust-pending",
                severity: .warning,
                title: "Hardware verification is incomplete",
                detail: "This Mac is online, but it cannot receive network work until MDM verification completes.",
                recoveryTitle: "Review verification"
            )
        case .stale:
            result.runState = .stale
            result.sourceUpdatedAt = sampledAt.addingTimeInterval(-186)
            result.currentModel = nil
            result.localEndpoint?.isReachable = false
            result.connectivity = ProviderConnectivitySnapshot(
                reconnectCount: 3,
                lastError: "Provider state has not updated"
            )
            result.lastProblem = ProviderProblem(
                id: "provider-state-stale",
                severity: .critical,
                title: "Darkbloom stopped checking in",
                detail: "The provider process may be asleep or unresponsive.",
                recoveryTitle: "Restart Darkbloom"
            )
        }
        return result
    }

    private func start() async throws {
        guard snapshot.runState == .paused else {
            throw ProviderRuntimeServiceError.actionUnavailable(.start, state: snapshot.runState)
        }

        transition(to: .starting)
        try await Task.sleep(for: transitionDelay)

        let now = nextDate()
        snapshot.sampledAt = now
        snapshot.sourceUpdatedAt = now
        snapshot.runState = .online
        snapshot.pid = 7_304 + Int32(sequence)
        snapshot.startedAt = now
        snapshot.availability = usesScheduledAvailability
            ? ProviderAvailabilitySnapshot(
                state: .scheduledActive,
                summary: "Weeknights, 8:00 PM–7:00 AM",
                nextChangeAt: Self.scheduledActiveReferenceDate.addingTimeInterval(31_200)
            )
            : ProviderAvailabilitySnapshot(
                state: .alwaysAvailable,
                summary: "Available whenever Darkbloom is running",
                nextChangeAt: nil
            )
        snapshot.activity = ProviderActivitySnapshot(requestsServed: 0, tokensGenerated: 0, usageGaps: 0)
        snapshot.capacity = Self.fixture(for: .online).capacity
        snapshot.currentModel = nil
        snapshot.warmModels = [Self.defaultModel]
        snapshot.lastProblem = nil
        snapshot.localEndpoint = Self.fixture(for: .online).localEndpoint
        snapshot.connectivity = nil
        publish()
    }

    private func stop() async throws {
        guard snapshot.runState != .paused, snapshot.runState != .stopping else {
            throw ProviderRuntimeServiceError.actionUnavailable(.stop, state: snapshot.runState)
        }

        transition(to: .stopping)
        try await Task.sleep(for: transitionDelay)

        let now = nextDate()
        snapshot.sampledAt = now
        snapshot.sourceUpdatedAt = now
        snapshot.runState = .paused
        snapshot.pid = nil
        snapshot.startedAt = nil
        snapshot.availability = ProviderAvailabilitySnapshot(
            state: .paused,
            summary: "Paused by you",
            nextChangeAt: nil
        )
        snapshot.capacity = nil
        snapshot.currentModel = nil
        snapshot.warmModels = []
        snapshot.localEndpoint = nil
        snapshot.connectivity = nil
        publish()
    }

    private func restart() async throws {
        guard snapshot.runState != .starting,
              snapshot.runState != .stopping,
              snapshot.runState != .restarting
        else {
            throw ProviderRuntimeServiceError.actionUnavailable(.restart, state: snapshot.runState)
        }

        // Capture the schedule gate before publishing the transient restart
        // state. A restart reloads configuration; it must not turn an
        // out-of-window provider into an always-available one.
        let wasScheduledOff = snapshot.runState == .scheduledOff
        let scheduledAvailability = snapshot.availability
        transition(to: .restarting)
        try await Task.sleep(for: transitionDelay)

        let now = nextDate()
        let priorPID = snapshot.pid ?? 7_304
        snapshot.sampledAt = now
        snapshot.sourceUpdatedAt = now
        snapshot.runState = wasScheduledOff ? .scheduledOff : .online
        snapshot.pid = priorPID + 1
        snapshot.startedAt = now
        snapshot.availability = if wasScheduledOff {
            scheduledAvailability
        } else if usesScheduledAvailability {
            ProviderAvailabilitySnapshot(
                state: .scheduledActive,
                summary: "Weeknights, 8:00 PM–7:00 AM",
                nextChangeAt: Self.scheduledActiveReferenceDate.addingTimeInterval(31_200)
            )
        } else {
            ProviderAvailabilitySnapshot(
                state: .alwaysAvailable,
                summary: "Available whenever Darkbloom is running",
                nextChangeAt: nil
            )
        }
        snapshot.activity = ProviderActivitySnapshot(requestsServed: 0, tokensGenerated: 0, usageGaps: 0)
        snapshot.capacity = wasScheduledOff
            ? Self.fixture(for: .scheduledOff).capacity
            : Self.fixture(for: .online).capacity
        snapshot.currentModel = nil
        snapshot.warmModels = wasScheduledOff ? [] : [Self.defaultModel]
        snapshot.lastProblem = nil
        snapshot.localEndpoint = wasScheduledOff
            ? nil
            : Self.fixture(for: .online).localEndpoint
        snapshot.connectivity = nil
        publish()
    }

    private func transition(to state: ProviderRunState) {
        let now = nextDate()
        snapshot.sampledAt = now
        snapshot.sourceUpdatedAt = now
        snapshot.runState = state
        publish()
    }

    private func touch(sourceDidUpdate: Bool) {
        let now = nextDate()
        snapshot.sampledAt = now
        if sourceDidUpdate {
            snapshot.sourceUpdatedAt = now
        }
    }

    private func nextDate() -> Date {
        sequence += 1
        return snapshot.sampledAt.addingTimeInterval(1)
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
