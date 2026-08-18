import Foundation

enum MyMacsMappingError: Error, Equatable, Sendable {
    case missingMachineIdentity(providerID: String)
    case duplicateMachineIdentity(String)
    case invalidMoneyField(String)
}

struct MyMac: Equatable, Identifiable, Sendable {
    let identity: MyMacIdentity
    /// Current coordinator connection/session identifier.
    var providerID: String
    /// Optional X25519 earnings-link key; not physical-machine identity.
    var providerKey: String?
    var accountID: String?
    var lifecycle: MyMacLifecycle

    var serialNumber: String?
    var secureEnclavePublicKey: String?
    var hardware: MyMacHardwareSnapshot?
    /// `nil` means the model catalog was not reported; `[]` means it was
    /// reported and the provider advertised no models.
    var models: [MyMacModelSnapshot]?
    var backend: String?

    var trust: MyMacTrustSnapshot
    var version: MyMacVersionSnapshot
    var challenge: MyMacChallengeSnapshot
    var live: MyMacLiveSnapshot?
    var attention: MyMacAttentionSnapshot
    var reputation: MyMacReputationSnapshot?

    var lifetimeRequestsServed: Int64?
    var lifetimeTokensGenerated: Int64?
    /// Timestamp of the merged provider record/session. It is not physical Mac
    /// age and is not guaranteed to be the machine's first network join.
    var registeredAt: Date?
    var lastSeen: Date?

    var id: String { identity.id }

    var maskedSerialNumber: String? {
        MyMacSensitiveIdentifier.masked(serialNumber)
    }

    /// The coordinator accepts deletion only for retained offline records.
    /// `untrusted` is intentionally ineligible because it can still represent
    /// a live registry connection.
    var canRemove: Bool {
        lifecycle == .offline || lifecycle == .neverSeen
    }

    /// Raw coordinator path token, available only when removal is eligible.
    /// This must never use the prefixed SwiftUI identity key.
    var removalToken: String? {
        guard canRemove else { return nil }
        return Self.normalized(serialNumber) ?? Self.normalized(providerID)
    }

    init(
        wire: MyMacsProviderWireRecord,
        context: MyMacsProviderContext,
        asOf: Date
    ) throws {
        guard let identity = MyMacIdentity.resolve(
            serialNumber: wire.serialNumber,
            secureEnclavePublicKey: wire.sePublicKey,
            providerSessionID: wire.providerID
        ) else {
            throw MyMacsMappingError.missingMachineIdentity(providerID: wire.providerID)
        }

        let lifecycle = MyMacLifecycle(coordinatorValue: wire.status)
        let trust = MyMacTrustSnapshot(
            level: MyMacTrustLevel(coordinatorValue: wire.trustLevel),
            attested: wire.attested,
            appleDeviceAttestationVerified: wire.mdaVerified,
            secureEnclaveKeyBound: wire.seKeyBound,
            secureEnclaveAvailable: wire.secureEnclave,
            runtimeVerified: wire.runtimeVerified
        )
        let version = MyMacVersionSnapshot(
            installed: wire.version,
            latest: context.latestProviderVersion,
            minimum: context.minimumProviderVersion
        )
        let challenge = MyMacChallengeSnapshot(
            lastVerifiedAt: wire.lastChallengeVerified,
            failedAttempts: wire.failedChallenges ?? 0,
            maximumAge: TimeInterval(context.challengeMaximumAgeSeconds),
            lifecycle: lifecycle,
            asOf: asOf
        )
        let models = wire.models?.map(Self.model)
        let live = Self.liveSnapshot(wire: wire, lifecycle: lifecycle)

        self.identity = identity
        providerID = Self.normalized(wire.providerID) ?? wire.providerID
        providerKey = Self.normalized(wire.providerKey)
        accountID = Self.normalized(wire.accountID)
        self.lifecycle = lifecycle
        serialNumber = Self.normalized(wire.serialNumber)
        secureEnclavePublicKey = Self.normalized(wire.sePublicKey)
        hardware = wire.hardware.flatMap(Self.hardware)
        self.models = models
        backend = Self.normalized(wire.backend)
        self.trust = trust
        self.version = version
        self.challenge = challenge
        self.live = live
        attention = MyMacAttentionSnapshot.derive(
            lifecycle: lifecycle,
            trust: trust,
            version: version,
            challenge: challenge,
            models: models,
            live: live
        )
        reputation = wire.reputation.map(Self.reputationSnapshot)
        lifetimeRequestsServed = wire.lifetimeRequestsServed
        lifetimeTokensGenerated = wire.lifetimeTokensGenerated
        registeredAt = wire.registeredAt
        lastSeen = wire.lastSeen
    }

    private static func hardware(
        _ wire: MyMacsHardwareWireRecord
    ) -> MyMacHardwareSnapshot? {
        let snapshot = MyMacHardwareSnapshot(
            machineModel: normalized(wire.machineModel),
            chipName: normalized(wire.chipName),
            chipFamily: normalized(wire.chipFamily),
            chipTier: normalized(wire.chipTier),
            memoryGB: positive(wire.memoryGB),
            memoryAvailableGB: positive(wire.memoryAvailableGB),
            cpuCoreCount: positive(wire.cpuCores?.total),
            performanceCoreCount: positive(wire.cpuCores?.performance),
            efficiencyCoreCount: positive(wire.cpuCores?.efficiency),
            gpuCoreCount: positive(wire.gpuCores),
            memoryBandwidthGBs: positive(wire.memoryBandwidthGBs)
        )
        let hasReportedFact = snapshot.machineModel != nil ||
            snapshot.chipName != nil ||
            snapshot.chipFamily != nil ||
            snapshot.chipTier != nil ||
            snapshot.memoryGB != nil ||
            snapshot.memoryAvailableGB != nil ||
            snapshot.cpuCoreCount != nil ||
            snapshot.performanceCoreCount != nil ||
            snapshot.efficiencyCoreCount != nil ||
            snapshot.gpuCoreCount != nil ||
            snapshot.memoryBandwidthGBs != nil
        return hasReportedFact ? snapshot : nil
    }

    private static func model(_ wire: MyMacsModelWireRecord) -> MyMacModelSnapshot {
        MyMacModelSnapshot(
            id: wire.id,
            sizeBytes: wire.sizeBytes,
            modelType: normalized(wire.modelType),
            quantization: normalized(wire.quantization),
            isVision: wire.isVision,
            templateRenderOK: wire.templateRenderOK
        )
    }

    private static func reputationSnapshot(
        _ wire: MyMacsReputationWireRecord
    ) -> MyMacReputationSnapshot {
        MyMacReputationSnapshot(
            score: wire.score,
            totalJobs: wire.totalJobs,
            successfulJobs: wire.successfulJobs,
            failedJobs: wire.failedJobs,
            recordedUptimeSeconds: wire.totalUptimeSeconds,
            averageResponseTimeMilliseconds: wire.averageResponseTimeMS,
            challengesPassed: wire.challengesPassed,
            challengesFailed: wire.challengesFailed
        )
    }

    private static func liveSnapshot(
        wire: MyMacsProviderWireRecord,
        lifecycle: MyMacLifecycle
    ) -> MyMacLiveSnapshot? {
        // Offline payloads contain zero-valued live fields in the Go wire shape.
        // Do not turn those placeholders into authoritative measurements.
        let canContainLiveData = lifecycle == .serving ||
            lifecycle == .online ||
            lifecycle == .untrusted ||
            wire.online == true
        guard canContainLiveData else { return nil }

        let capacity = capacitySource(wire: wire)
        let metrics = wire.systemMetrics.map {
            MyMacSystemMetricsSnapshot(
                memoryPressure: $0.memoryPressure,
                cpuUsage: $0.cpuUsage,
                thermalState: normalized($0.thermalState)
            )
        }
        let hasLiveData = wire.lastHeartbeat != nil ||
            metrics != nil ||
            capacity != .unavailable ||
            wire.pendingRequests != nil ||
            wire.maxConcurrency != nil ||
            wire.prefillTPS != nil ||
            wire.decodeTPS != nil
        guard hasLiveData else { return nil }

        return MyMacLiveSnapshot(
            lastHeartbeat: wire.lastHeartbeat,
            systemMetrics: metrics,
            capacity: capacity,
            pendingRequests: wire.pendingRequests,
            maximumConcurrency: wire.maxConcurrency,
            prefillTPS: wire.prefillTPS,
            decodeTPS: wire.decodeTPS
        )
    }

    private static func capacitySource(
        wire: MyMacsProviderWireRecord
    ) -> MyMacCapacitySource {
        if let backend = wire.backendCapacity {
            return .backendSlots(MyMacBackendCapacitySnapshot(
                slots: backend.slots.map { slot in
                    MyMacBackendSlotSnapshot(
                        modelID: slot.model,
                        state: MyMacBackendSlotState(coordinatorValue: slot.state),
                        runningRequestCount: slot.numRunning,
                        waitingRequestCount: slot.numWaiting,
                        maximumConcurrency: slot.maxConcurrency,
                        activeTokens: slot.activeTokens,
                        maximumPotentialTokens: slot.maxTokensPotential,
                        observedDecodeTPS: slot.observedDecodeTPS,
                        observedPrefillTPS: slot.observedPrefillTPS,
                        activeTokenBudgetUsed: slot.activeTokenBudgetUsed,
                        activeTokenBudgetMaximum: slot.activeTokenBudgetMax,
                        queuedTokenBudget: slot.queuedTokenBudget,
                        modelLoadTimeMS: slot.modelLoadTimeMS
                    )
                },
                gpuMemoryActiveGB: backend.gpuMemoryActiveGB,
                gpuMemoryPeakGB: backend.gpuMemoryPeakGB,
                gpuMemoryCacheGB: backend.gpuMemoryCacheGB,
                totalMemoryGB: backend.totalMemoryGB,
                freeForLoadGB: backend.freeForLoadGB
            ))
        }

        if wire.warmModels != nil || normalized(wire.currentModel) != nil {
            return .legacy(MyMacLegacyCapacitySnapshot(
                currentModelID: normalized(wire.currentModel),
                warmModelIDs: wire.warmModels ?? []
            ))
        }
        return .unavailable
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

struct MyMacsProviderContext: Equatable, Sendable {
    var latestProviderVersion: String
    var minimumProviderVersion: String
    var heartbeatTimeoutSeconds: Int
    var challengeMaximumAgeSeconds: Int
}

struct MyMacsFleetCounts: Equatable, Sendable {
    var total: Int
    var online: Int
    var serving: Int
    var offline: Int
    var untrusted: Int
    var hardwareTrusted: Int
    var needingAttention: Int
}

struct MyMacsAccountSummary: Equatable, Sendable {
    var accountID: String
    var availableBalance: MicroUSD
    var withdrawableBalance: MicroUSD
    var payoutReady: Bool
    var lifetimeEarnings: MicroUSD
    var lifetimeJobs: Int64
    var last24HoursEarnings: MicroUSD
    var last24HoursJobs: Int64
    var last7DaysEarnings: MicroUSD
    var last7DaysJobs: Int64
    var counts: MyMacsFleetCounts
}

struct MyMacsSnapshot: Equatable, Sendable {
    var asOf: Date
    var context: MyMacsProviderContext
    var macs: [MyMac]
    /// The providers endpoint is sufficient to render inventory. Summary is
    /// best-effort and remains nil when only that secondary request failed.
    var accountSummary: MyMacsAccountSummary?

    init(
        providers: MyMacsProvidersWireResponse,
        summary: MyMacsSummaryWireResponse?,
        asOf: Date
    ) throws {
        let context = MyMacsProviderContext(
            latestProviderVersion: providers.latestProviderVersion,
            minimumProviderVersion: providers.minimumProviderVersion,
            heartbeatTimeoutSeconds: providers.heartbeatTimeoutSeconds,
            challengeMaximumAgeSeconds: providers.challengeMaxAgeSeconds
        )
        let macs = try providers.providers.map {
            try MyMac(wire: $0, context: context, asOf: asOf)
        }
        var seen = Set<String>()
        for mac in macs where !seen.insert(mac.id).inserted {
            throw MyMacsMappingError.duplicateMachineIdentity(mac.id)
        }

        self.asOf = asOf
        self.context = context
        self.macs = macs
        accountSummary = try summary.map(Self.summary)
    }

    private static func summary(
        _ wire: MyMacsSummaryWireResponse
    ) throws -> MyMacsAccountSummary {
        func money(_ value: Int64, field: String) throws -> MicroUSD {
            guard let value = MicroUSD(validating: value) else {
                throw MyMacsMappingError.invalidMoneyField(field)
            }
            return value
        }

        return try MyMacsAccountSummary(
            accountID: wire.accountID,
            availableBalance: money(
                wire.availableBalanceMicroUSD,
                field: "available_balance_micro_usd"
            ),
            withdrawableBalance: money(
                wire.withdrawableBalanceMicroUSD,
                field: "withdrawable_balance_micro_usd"
            ),
            payoutReady: wire.payoutReady,
            lifetimeEarnings: money(wire.lifetimeMicroUSD, field: "lifetime_micro_usd"),
            lifetimeJobs: wire.lifetimeJobs,
            last24HoursEarnings: money(wire.last24hMicroUSD, field: "last_24h_micro_usd"),
            last24HoursJobs: wire.last24hJobs,
            last7DaysEarnings: money(wire.last7dMicroUSD, field: "last_7d_micro_usd"),
            last7DaysJobs: wire.last7dJobs,
            counts: MyMacsFleetCounts(
                total: wire.counts.total,
                online: wire.counts.online,
                serving: wire.counts.serving,
                offline: wire.counts.offline,
                untrusted: wire.counts.untrusted,
                hardwareTrusted: wire.counts.hardware,
                needingAttention: wire.counts.needsAttention
            )
        )
    }
}
