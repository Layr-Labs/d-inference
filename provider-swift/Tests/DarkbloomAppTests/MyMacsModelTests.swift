import Foundation
import Testing
@testable import DarkbloomApp

@Test("Mac identity uses the opaque provider ID without interpreting hardware keys")
func myMacIdentityUsesOpaqueProviderID() throws {
    let identity = try #require(MyMacIdentity.resolve(providerID: "provider/opaque:0001"))
    #expect(identity.value == "provider/opaque:0001")
    #expect(identity.id == "provider-id:provider/opaque:0001")
    #expect(MyMacIdentity.resolve(providerID: "provider/opaque:0002") != identity)
    #expect(MyMacIdentity.resolve(providerID: "") == nil)
    #expect(MyMacIdentity.resolve(providerID: "  ") == nil)
    #expect(MyMacIdentity.resolve(providerID: " opaque ")?.value == " opaque ")
}

@Test("Removal uses coordinator lifecycle and only the opaque provider ID")
@MainActor
func myMacRemovalContractMatchesCoordinatorDeletePath() throws {
    let snapshot = try #require(MyMacsStore(fixture: .ready).snapshot)

    let offline = try #require(snapshot.macs.first { $0.lifecycle == .offline })
    #expect(offline.canRemove)
    #expect(offline.removalToken == offline.providerID)
    #expect(offline.removalToken != offline.id)

    let neverSeen = try #require(snapshot.macs.first { $0.lifecycle == .neverSeen })
    #expect(neverSeen.canRemove)
    #expect(neverSeen.removalToken == "preview-session-never-seen")
    #expect(neverSeen.removalToken != neverSeen.id)

    for lifecycle in [MyMacLifecycle.serving, .online, .untrusted] {
        let mac = try #require(snapshot.macs.first { $0.lifecycle == lifecycle })
        #expect(!mac.canRemove)
        #expect(mac.removalToken == nil)
    }
}

@Test("Inventory fixtures cover every coordinator lifecycle without inventing missing data")
@MainActor
func myMacInventoryCoversLifecyclesAndOptionality() throws {
    let store = MyMacsStore(fixture: .ready)
    let snapshot = try #require(store.snapshot)

    #expect(Set(snapshot.macs.map(\.lifecycle)) == Set([
        .serving,
        .online,
        .offline,
        .neverSeen,
        .untrusted,
    ]))

    let offline = try #require(snapshot.macs.first { $0.lifecycle == .offline })
    #expect(offline.providerKey == "preview-x25519-mini-persisted")
    #expect(offline.identity.value == offline.providerID)
    #expect(offline.live == nil)
    #expect(offline.challenge.freshness == .notApplicable)
    #expect(offline.version.disposition == .belowMinimum)
    #expect(offline.attention.level == .blocking)

    let neverSeen = try #require(snapshot.macs.first { $0.lifecycle == .neverSeen })
    #expect(neverSeen.providerKey == nil)
    #expect(neverSeen.identity.value == neverSeen.providerID)
    #expect(neverSeen.hardware == nil)
    #expect(neverSeen.models == nil)
    #expect(neverSeen.reputation == nil)
    #expect(neverSeen.lifetimeRequestsServed == nil)
    #expect(neverSeen.live == nil)
}

@Test("Reputation maps only coordinator-reported counters and preserves absence")
@MainActor
func myMacReputationPreservesCoordinatorOptionality() throws {
    let snapshot = try #require(MyMacsStore(fixture: .ready).snapshot)
    let serving = try #require(snapshot.macs.first { $0.lifecycle == .serving })
    let reputation = try #require(serving.reputation)

    #expect(reputation.score == 0.97)
    #expect(reputation.totalJobs == 214)
    #expect(reputation.successfulJobs == 210)
    #expect(reputation.failedJobs == 4)
    #expect(reputation.recordedUptimeSeconds == 604_800)
    #expect(reputation.averageResponseTimeMilliseconds == 420)
    #expect(reputation.challengesPassed == 1_044)
    #expect(reputation.challengesFailed == 0)

    let neverSeen = try #require(snapshot.macs.first { $0.lifecycle == .neverSeen })
    #expect(neverSeen.reputation == nil)
}

@Test("Backend slots are authoritative and legacy capacity remains an explicit fallback")
@MainActor
func myMacBackendCapacityAuthorityIsExplicit() throws {
    let snapshot = try #require(MyMacsStore(fixture: .ready).snapshot)
    let serving = try #require(snapshot.macs.first { $0.lifecycle == .serving })
    let online = try #require(snapshot.macs.first { $0.lifecycle == .online })

    guard case .backendSlots(let backend) = serving.live?.capacity else {
        Issue.record("Serving fixture should use backend slot authority")
        return
    }
    #expect(backend.slots.map(\.modelID) == ["gpt-oss-20b"])
    #expect(!backend.slots.map(\.modelID).contains("legacy-value-must-not-win"))

    guard case .legacy(let legacy) = online.live?.capacity else {
        Issue.record("Legacy fields should be represented only without backend capacity")
        return
    }
    #expect(legacy.currentModelID == "gemma-4-26b-qat-4bit")
    #expect(legacy.warmModelIDs == ["gemma-4-26b-qat-4bit"])
}

@Test("Trust, challenge, version, and attention are independent state axes")
@MainActor
func myMacOperationalAxesRemainIndependent() throws {
    let snapshot = try #require(MyMacsStore(fixture: .ready).snapshot)
    let serving = try #require(snapshot.macs.first { $0.lifecycle == .serving })
    #expect(serving.trust.level == .hardware)
    #expect(serving.challenge.freshness == .fresh)
    #expect(serving.version.disposition == .current)
    #expect(serving.attention.level == .none)

    let online = try #require(snapshot.macs.first { $0.lifecycle == .online })
    #expect(online.trust.level == .hardware)
    #expect(online.challenge.freshness == .fresh)
    #expect(online.version.disposition == .updateAvailable)
    #expect(online.attention.level == .none)
    #expect(online.attention.operationalLevel == .degraded)
    #expect(online.attention.operationalNotices.contains {
        $0.reason == .providerUpdateAvailable && $0.level == .notice
    })
    #expect(online.attention.operationalNotices.contains {
        $0.reason == .thermalFair && $0.level == .degraded
    })

    let untrusted = try #require(snapshot.macs.first { $0.lifecycle == .untrusted })
    #expect(untrusted.challenge.failedAttempts == 3)
    #expect(untrusted.challenge.freshness == .notApplicable)
    #expect(untrusted.attention.level == .blocking)
}

@Test("Challenge freshness remains separate from coordinator attention")
func myMacChallengeFreshnessUsesCoordinatorWindow() {
    let now = Date(timeIntervalSince1970: 10_000)
    let awaiting = MyMacChallengeSnapshot(
        lastVerifiedAt: nil,
        failedAttempts: 0,
        maximumAge: 360,
        lifecycle: .online,
        asOf: now
    )
    #expect(awaiting.freshness == .awaitingFirstVerification)

    let stale = MyMacChallengeSnapshot(
        lastVerifiedAt: now.addingTimeInterval(-361),
        failedAttempts: 0,
        maximumAge: 360,
        lifecycle: .serving,
        asOf: now
    )
    #expect(stale.freshness == .stale)

    let offline = MyMacChallengeSnapshot(
        lastVerifiedAt: now.addingTimeInterval(-10_000),
        failedAttempts: 0,
        maximumAge: 360,
        lifecycle: .offline,
        asOf: now
    )
    #expect(offline.freshness == .notApplicable)
}

@Test("Malformed and development provider versions remain unknown")
func myMacVersionDoesNotPromoteUnparseableValuesToCurrent() {
    #expect(MyMacVersionSnapshot(
        installed: "dev-build",
        latest: "0.7.9",
        minimum: "0.7.5"
    ).disposition == .unknown)
    #expect(MyMacVersionSnapshot(
        installed: "0.7.9",
        latest: "nightly",
        minimum: "0.7.5"
    ).disposition == .unknown)
    #expect(MyMacVersionSnapshot(
        installed: "0.7.9",
        latest: "0.7.9",
        minimum: "development"
    ).disposition == .unknown)
}

@Test("Go timestamps and zero-filled hardware decode through the My Macs boundary")
func myMacsWireDecoderHandlesGoDatesAndHardwareSentinels() throws {
    let data = try #require("""
    {
      "providers": [
        {
          "id": "session-zero-hardware",
          "account_id": "preview-account",
          "status": "offline",
          "online": false,
          "last_heartbeat": "2026-07-18T19:20:30.123456789Z",
          "hardware": {
            "machine_model": "",
            "chip_name": "",
            "chip_family": "",
            "chip_tier": "",
            "memory_gb": 0,
            "memory_available_gb": 0,
            "cpu_cores": {"total": 0, "performance": 0, "efficiency": 0},
            "gpu_cores": 0,
            "memory_bandwidth_gbs": 0
          },
          "models": [],
          "serial_number": "  RAW-SERIAL-01  ",
          "registered_at": "2026-07-18T19:20:30Z",
          "last_seen": "2026-07-18T12:20:30-07:00"
        },
        {
          "id": "  session-partial  ",
          "account_id": "preview-account",
          "status": "never_seen",
          "online": false,
          "hardware": {
            "machine_model": "",
            "chip_name": "Apple M4 Pro",
            "chip_family": "M4",
            "chip_tier": "",
            "memory_gb": 0,
            "memory_available_gb": 0,
            "cpu_cores": {"total": 14, "performance": 0, "efficiency": 0},
            "gpu_cores": 20,
            "memory_bandwidth_gbs": 0
          },
          "models": [],
          "se_public_key": "se-partial",
          "registered_at": "2026-07-18T19:20:30.987654321+00:00"
        }
      ],
      "latest_provider_version": "0.7.9",
      "min_provider_version": "0.7.5",
      "heartbeat_timeout_seconds": 90,
      "challenge_max_age_seconds": 360
    }
    """.data(using: .utf8))

    let response = try MyMacsWireDecoder().decodeProviders(from: data)
    let firstWire = try #require(response.providers.first)
    let lastHeartbeat = try #require(firstWire.lastHeartbeat)
    let registeredAt = try #require(firstWire.registeredAt)
    let lastSeen = try #require(firstWire.lastSeen)
    #expect(abs(lastHeartbeat.timeIntervalSince(registeredAt) - 0.123_456_789) < 0.000_001)
    #expect(abs(lastSeen.timeIntervalSince(registeredAt)) < 0.000_001)

    let snapshot = try MyMacsSnapshot(
        providers: response,
        summary: nil,
        asOf: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let zeroHardware = try #require(snapshot.macs.first {
        $0.providerID == "session-zero-hardware"
    })
    #expect(zeroHardware.hardware == nil)
    #expect(zeroHardware.canRemove)
    #expect(zeroHardware.removalToken == "session-zero-hardware")
    #expect(zeroHardware.id == "provider-id:session-zero-hardware")
    #expect(firstWire.serialNumber == nil)

    let partial = try #require(snapshot.macs.first {
        $0.providerID == "  session-partial  "
    })
    let hardware = try #require(partial.hardware)
    #expect(hardware.machineModel == nil)
    #expect(hardware.chipName == "Apple M4 Pro")
    #expect(hardware.chipFamily == "M4")
    #expect(hardware.memoryGB == nil)
    #expect(hardware.cpuCoreCount == 14)
    #expect(hardware.performanceCoreCount == nil)
    #expect(hardware.efficiencyCoreCount == nil)
    #expect(hardware.gpuCoreCount == 20)
    #expect(hardware.memoryBandwidthGBs == nil)
    #expect(partial.removalToken == "  session-partial  ")
    #expect(partial.removalToken != partial.id)
}

@Test("Per-Mac attention exactly mirrors the coordinator summary predicate")
@MainActor
func myMacAttentionMatchesCoordinatorSummaryCount() throws {
    let snapshot = try #require(MyMacsStore(fixture: .ready).snapshot)
    let summary = try #require(snapshot.accountSummary)
    let locallyMirroredCount = snapshot.macs.filter(\.attention.requiresAttention).count

    #expect(locallyMirroredCount == summary.counts.needingAttention)
    let online = try #require(snapshot.macs.first { $0.lifecycle == .online })
    #expect(!online.attention.requiresAttention)
    #expect(!online.attention.operationalNotices.isEmpty)
}

@Test("Minimal wire records decode absent hardware and live values as absent")
func myMacWireDecodingDoesNotTurnMissingFieldsIntoZero() throws {
    let data = try #require("""
    {
      "providers": [{
        "id": "session-minimal",
        "status": "never_seen",
        "provider_key": null,
        "se_public_key": "se-minimal"
      }],
      "latest_provider_version": "0.7.9",
      "min_provider_version": "0.7.5",
      "heartbeat_timeout_seconds": 90,
      "challenge_max_age_seconds": 360
    }
    """.data(using: .utf8))
    let response = try MyMacsWireDecoder().decodeProviders(from: data)
    let record = try #require(response.providers.first)

    #expect(record.providerKey == nil)
    #expect(record.hardware == nil)
    #expect(record.models == nil)
    #expect(record.pendingRequests == nil)
    #expect(record.maxConcurrency == nil)
    #expect(record.systemMetrics == nil)
    #expect(record.backendCapacity == nil)
    #expect(record.reputation == nil)

    let snapshot = try MyMacsSnapshot(providers: response, summary: nil, asOf: .now)
    let mac = try #require(snapshot.macs.first)
    #expect(mac.hardware == nil)
    #expect(mac.live == nil)
    #expect(mac.reputation == nil)
}
