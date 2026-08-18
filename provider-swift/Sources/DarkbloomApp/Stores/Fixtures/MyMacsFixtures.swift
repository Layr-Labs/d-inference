import Foundation

struct MyMacsFixtureState: Equatable, Sendable {
    var availability: MyMacsAvailability
    var snapshot: MyMacsSnapshot?
}

enum MyMacsFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_784_413_800)
    static let refreshFailureDate = referenceDate.addingTimeInterval(45)

    static func make(_ fixture: MyMacsFixture) -> MyMacsFixtureState {
        switch fixture {
        case .loading:
            return MyMacsFixtureState(availability: .loading, snapshot: nil)

        case .ready:
            return MyMacsFixtureState(
                availability: .ready(lastUpdated: referenceDate, summary: .available),
                snapshot: try! snapshot(providers: activeProviders, summary: activeSummary)
            )

        case .partialSummary:
            return MyMacsFixtureState(
                availability: .ready(
                    lastUpdated: referenceDate,
                    summary: .unavailable(
                        message: "Machine status is current, but the account summary is unavailable."
                    )
                ),
                snapshot: try! snapshot(providers: activeProviders, summary: nil)
            )

        case .empty:
            return MyMacsFixtureState(
                availability: .ready(lastUpdated: referenceDate, summary: .available),
                snapshot: try! snapshot(providers: emptyProviders, summary: emptySummary)
            )

        case .signedOut:
            return MyMacsFixtureState(availability: .signedOut, snapshot: nil)

        case .unavailable:
            return MyMacsFixtureState(
                availability: .unavailable(
                    message: "Darkbloom could not load the Macs linked to this account."
                ),
                snapshot: nil
            )

        case .staleRetained:
            return MyMacsFixtureState(
                availability: .staleRetained(
                    lastUpdated: referenceDate,
                    failedAt: refreshFailureDate,
                    message: "Refresh failed. Showing the last account snapshot.",
                    summary: .available
                ),
                snapshot: try! snapshot(providers: activeProviders, summary: activeSummary)
            )
        }
    }

    private static func snapshot(
        providers: MyMacsProvidersWireResponse,
        summary: MyMacsSummaryWireResponse?
    ) throws -> MyMacsSnapshot {
        try MyMacsSnapshot(providers: providers, summary: summary, asOf: referenceDate)
    }

    private static var activeProviders: MyMacsProvidersWireResponse {
        MyMacsProvidersWireResponse(
            providers: [
                servingMacBook,
                onlineStudio,
                offlineMini,
                neverSeenMac,
                untrustedStudio,
            ],
            latestProviderVersion: "0.7.9",
            minimumProviderVersion: "0.7.5",
            heartbeatTimeoutSeconds: 90,
            challengeMaxAgeSeconds: 360
        )
    }

    private static var emptyProviders: MyMacsProvidersWireResponse {
        MyMacsProvidersWireResponse(
            providers: [],
            latestProviderVersion: "0.7.9",
            minimumProviderVersion: "0.7.5",
            heartbeatTimeoutSeconds: 90,
            challengeMaxAgeSeconds: 360
        )
    }

    private static var activeSummary: MyMacsSummaryWireResponse {
        MyMacsSummaryWireResponse(
            accountID: "preview-account",
            availableBalanceMicroUSD: 12_850_000,
            withdrawableBalanceMicroUSD: 10_500_000,
            payoutReady: true,
            lifetimeMicroUSD: 31_740_000,
            lifetimeJobs: 428,
            last24hMicroUSD: 1_460_000,
            last24hJobs: 18,
            last7dMicroUSD: 8_920_000,
            last7dJobs: 104,
            counts: MyMacsFleetCountsWireRecord(
                total: 5,
                online: 1,
                serving: 1,
                offline: 2,
                untrusted: 1,
                hardware: 3,
                needsAttention: 3
            ),
            latestProviderVersion: "0.7.9",
            minimumProviderVersion: "0.7.5"
        )
    }

    private static var emptySummary: MyMacsSummaryWireResponse {
        MyMacsSummaryWireResponse(
            accountID: "preview-account",
            availableBalanceMicroUSD: 0,
            withdrawableBalanceMicroUSD: 0,
            payoutReady: false,
            lifetimeMicroUSD: 0,
            lifetimeJobs: 0,
            last24hMicroUSD: 0,
            last24hJobs: 0,
            last7dMicroUSD: 0,
            last7dJobs: 0,
            counts: MyMacsFleetCountsWireRecord(
                total: 0,
                online: 0,
                serving: 0,
                offline: 0,
                untrusted: 0,
                hardware: 0,
                needsAttention: 0
            ),
            latestProviderVersion: "0.7.9",
            minimumProviderVersion: "0.7.5"
        )
    }

    private static var servingMacBook: MyMacsProviderWireRecord {
        provider(
            providerID: "preview-session-macbook-02",
            providerKey: "preview-x25519-macbook",
            status: "serving",
            serial: "FVFGH0STQ6L4",
            sePublicKey: "preview-se-key-macbook",
            model: "MacBook Pro",
            chip: "Apple M4 Max",
            memoryGB: 64,
            gpuCores: 40,
            version: "0.7.9",
            challengeAge: 55,
            failedChallenges: 0,
            trustLevel: "hardware",
            runtimeVerified: true,
            models: [model("gpt-oss-20b", sizeGB: 12, quantization: "4-bit")],
            backendCapacity: MyMacsBackendCapacityWireRecord(
                slots: [slot(model: "gpt-oss-20b", state: "running", running: 2)],
                gpuMemoryActiveGB: 22.4,
                gpuMemoryPeakGB: 28.8,
                gpuMemoryCacheGB: 3.1,
                totalMemoryGB: 64,
                freeForLoadGB: 18.2
            ),
            warmModels: ["legacy-value-must-not-win"],
            currentModel: "legacy-value-must-not-win",
            thermalState: "nominal"
        )
    }

    private static var onlineStudio: MyMacsProviderWireRecord {
        provider(
            providerID: "preview-session-studio-07",
            providerKey: "preview-x25519-studio",
            status: "online",
            serial: "H2YVQ0STUDIO",
            sePublicKey: "preview-se-key-studio",
            model: "Mac Studio",
            chip: "Apple M3 Ultra",
            memoryGB: 192,
            gpuCores: 80,
            version: "0.7.8",
            challengeAge: 90,
            failedChallenges: 0,
            trustLevel: "hardware",
            runtimeVerified: true,
            models: [model("gemma-4-26b-qat-4bit", sizeGB: 18, quantization: "4-bit")],
            backendCapacity: nil,
            warmModels: ["gemma-4-26b-qat-4bit"],
            currentModel: "gemma-4-26b-qat-4bit",
            thermalState: "fair"
        )
    }

    private static var offlineMini: MyMacsProviderWireRecord {
        var mac = provider(
            providerID: "preview-session-mini-11",
            // Persisted X25519 keys remain available for offline earnings
            // correlation; they are still not the card's machine identity.
            providerKey: "preview-x25519-mini-persisted",
            status: "offline",
            serial: "C07QMINI2025",
            sePublicKey: "preview-se-key-mini",
            model: "Mac mini",
            chip: "Apple M4 Pro",
            memoryGB: 48,
            gpuCores: 20,
            version: "0.7.3",
            challengeAge: 7_200,
            failedChallenges: 0,
            trustLevel: "hardware",
            runtimeVerified: true,
            models: [model("gpt-oss-20b", sizeGB: 12, quantization: "4-bit")],
            backendCapacity: nil,
            warmModels: nil,
            currentModel: nil,
            thermalState: nil
        )
        // The coordinator's offline payload can contain required zero values.
        // Domain mapping must still treat live metrics as absent.
        mac.pendingRequests = 0
        mac.maxConcurrency = 0
        mac.prefillTPS = 0
        mac.decodeTPS = 0
        return mac
    }

    private static var neverSeenMac: MyMacsProviderWireRecord {
        var mac = provider(
            providerID: "preview-session-never-seen",
            providerKey: nil,
            status: "never_seen",
            serial: nil,
            sePublicKey: "preview-se-key-never-seen",
            model: nil,
            chip: nil,
            memoryGB: nil,
            gpuCores: nil,
            version: nil,
            challengeAge: nil,
            failedChallenges: 0,
            trustLevel: "none",
            runtimeVerified: nil,
            models: nil,
            backendCapacity: nil,
            warmModels: nil,
            currentModel: nil,
            thermalState: nil
        )
        mac.reputation = nil
        return mac
    }

    private static var untrustedStudio: MyMacsProviderWireRecord {
        provider(
            providerID: "preview-session-untrusted-03",
            providerKey: "preview-x25519-untrusted",
            status: "untrusted",
            serial: "H2YUNTRUSTED",
            sePublicKey: "preview-se-key-untrusted",
            model: "Mac Studio",
            chip: "Apple M2 Max",
            memoryGB: 64,
            gpuCores: 38,
            version: "0.7.9",
            challengeAge: 600,
            failedChallenges: 3,
            trustLevel: "self_signed",
            runtimeVerified: true,
            models: [model("gpt-oss-20b", sizeGB: 12, quantization: "4-bit")],
            backendCapacity: MyMacsBackendCapacityWireRecord(
                slots: [slot(model: "gpt-oss-20b", state: "crashed", running: 0)],
                gpuMemoryActiveGB: 13.1,
                gpuMemoryPeakGB: 24.5,
                gpuMemoryCacheGB: 1.8,
                totalMemoryGB: 64,
                freeForLoadGB: 20
            ),
            warmModels: ["gpt-oss-20b"],
            currentModel: "gpt-oss-20b",
            thermalState: "serious"
        )
    }

    private static func provider(
        providerID: String,
        providerKey: String?,
        status: String,
        serial: String?,
        sePublicKey: String?,
        model: String?,
        chip: String?,
        memoryGB: Int?,
        gpuCores: Int?,
        version: String?,
        challengeAge: TimeInterval?,
        failedChallenges: Int,
        trustLevel: String,
        runtimeVerified: Bool?,
        models: [MyMacsModelWireRecord]?,
        backendCapacity: MyMacsBackendCapacityWireRecord?,
        warmModels: [String]?,
        currentModel: String?,
        thermalState: String?
    ) -> MyMacsProviderWireRecord {
        let isLive = status == "serving" || status == "online" || status == "untrusted"
        return MyMacsProviderWireRecord(
            providerID: providerID,
            accountID: "preview-account",
            status: status,
            online: status == "serving" || status == "online",
            lastHeartbeat: isLive ? referenceDate.addingTimeInterval(-20) : nil,
            hardware: model == nil && chip == nil && memoryGB == nil && gpuCores == nil
                ? nil
                : MyMacsHardwareWireRecord(
                    machineModel: model,
                    chipName: chip,
                    chipFamily: chip?.replacingOccurrences(of: "Apple ", with: ""),
                    chipTier: nil,
                    memoryGB: memoryGB,
                    memoryAvailableGB: nil,
                    cpuCores: nil,
                    gpuCores: gpuCores,
                    memoryBandwidthGBs: nil
                ),
            models: models,
            backend: "mlx-swift",
            version: version,
            serialNumber: serial,
            trustLevel: trustLevel,
            attested: trustLevel != "none",
            mdaVerified: trustLevel == "hardware",
            seKeyBound: trustLevel == "hardware",
            sePublicKey: sePublicKey,
            providerKey: providerKey,
            secureEnclave: trustLevel != "none",
            sipEnabled: true,
            secureBootEnabled: true,
            authenticatedRootEnabled: true,
            runtimeVerified: runtimeVerified,
            lastChallengeVerified: challengeAge.map {
                referenceDate.addingTimeInterval(-$0)
            },
            failedChallenges: failedChallenges,
            systemMetrics: isLive && thermalState != nil
                ? MyMacsSystemMetricsWireRecord(
                    memoryPressure: 0.28,
                    cpuUsage: 0.36,
                    thermalState: thermalState
                )
                : nil,
            backendCapacity: backendCapacity,
            warmModels: warmModels,
            currentModel: currentModel,
            pendingRequests: isLive ? 2 : nil,
            maxConcurrency: isLive ? 4 : nil,
            prefillTPS: isLive ? 248 : nil,
            decodeTPS: isLive ? 51 : nil,
            reputation: MyMacsReputationWireRecord(
                score: 0.97,
                totalJobs: 214,
                successfulJobs: 210,
                failedJobs: 4,
                totalUptimeSeconds: 604_800,
                averageResponseTimeMS: 420,
                challengesPassed: 1_044,
                challengesFailed: failedChallenges
            ),
            lifetimeRequestsServed: status == "never_seen" ? nil : 214,
            lifetimeTokensGenerated: status == "never_seen" ? nil : 1_482_304,
            registeredAt: referenceDate.addingTimeInterval(-2_592_000),
            lastSeen: status == "never_seen"
                ? nil
                : referenceDate.addingTimeInterval(isLive ? -20 : -86_400)
        )
    }

    private static func model(
        _ id: String,
        sizeGB: Int64,
        quantization: String
    ) -> MyMacsModelWireRecord {
        MyMacsModelWireRecord(
            id: id,
            sizeBytes: sizeGB * 1_073_741_824,
            modelType: "text",
            quantization: quantization,
            weightHash: nil,
            isVision: false,
            templateRenderOK: true
        )
    }

    private static func slot(
        model: String,
        state: String,
        running: Int
    ) -> MyMacsBackendSlotWireRecord {
        MyMacsBackendSlotWireRecord(
            model: model,
            state: state,
            numRunning: running,
            numWaiting: 0,
            maxConcurrency: 4,
            activeTokens: running > 0 ? 3_840 : 0,
            maxTokensPotential: running > 0 ? 8_192 : 0,
            observedDecodeTPS: 51,
            observedPrefillTPS: 248,
            activeTokenBudgetUsed: running > 0 ? 8_192 : 0,
            activeTokenBudgetMax: 32_768,
            queuedTokenBudget: 0,
            modelLoadTimeMS: 8_420
        )
    }
}
