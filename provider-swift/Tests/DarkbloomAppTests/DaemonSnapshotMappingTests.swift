import Foundation
import Testing
@testable import DarkbloomApp
import ProviderCoreFoundation

@Suite("Daemon snapshots map the daemon's files into app state")
struct DaemonSnapshotMappingTests {
    private let referenceNow = Date(timeIntervalSince1970: 1_784_500_000)

    private func freshState(
        pid: Int32 = 4242,
        trust: DaemonState.Trust? = nil,
        inferenceActive: Bool = false,
        schedule: DaemonState.SchedulePosture? = nil
    ) -> DaemonState {
        DaemonState(
            pid: pid,
            processIdentity: ProcessIdentity(pid: pid, startTimeMicros: 100),
            version: "0.8.5",
            writtenAt: referenceNow.timeIntervalSince1970 - 2,
            startedAt: referenceNow.timeIntervalSince1970 - 3_600,
            trust: trust,
            currentModel: "gpt-oss-20b",
            warmModels: ["gpt-oss-20b", "gemma-4-26b-qat-4bit"],
            inferenceActive: inferenceActive,
            stats: DaemonState.Stats(requestsServed: 41, tokensGenerated: 98_231, usageGaps: 2),
            system: DaemonState.SystemInfo(memoryPressure: 0.4, cpuUsage: 0.2, thermalState: "nominal"),
            capacity: DaemonState.Capacity(totalMemoryGb: 128, gpuMemoryActiveGb: 21.6, gpuMemoryCacheGb: 3.2),
            connectivity: DaemonState.Connectivity(reconnectCount: 1, lastError: nil),
            schedule: schedule
        )
    }

    private func scheduledOffState(
        age: TimeInterval = 2,
        nextChangeOffset: TimeInterval? = 3_600
    ) -> DaemonState {
        var state = freshState(schedule: .init(
            mode: "scheduled-off",
            summary: "Mon-Fri 09:00-17:00",
            nextChangeAtEpoch: nextChangeOffset.map {
                referenceNow.timeIntervalSince1970 + $0
            }
        ))
        state.writtenAt = referenceNow.timeIntervalSince1970 - age
        return state
    }

    private func inputs(
        state: DaemonState?,
        alive: Bool,
        loaded: Bool = true,
        endpoint: LocalEndpointInfo? = nil
    ) -> DaemonSnapshotMapping.Inputs {
        DaemonSnapshotMapping.Inputs(
            state: state,
            processIsAlive: alive,
            serviceIsLoaded: loaded,
            localEndpoint: endpoint,
            now: referenceNow,
            providerName: "Gaj’s Mac"
        )
    }

    @Test("No daemon → paused, empty, trust unknown")
    func noStateMapsPaused() {
        let snapshot = DaemonSnapshotMapping.map(inputs(state: nil, alive: false))
        #expect(snapshot.runState == .paused)
        #expect(snapshot.pid == nil)
        #expect(snapshot.isRunning == false)
        #expect(snapshot.trust.state == .unknown)
        #expect(snapshot.availability.state == .paused)
        #expect(snapshot.activity.requestsServed == 0)
        #expect(snapshot.warmModels.isEmpty)
        #expect(snapshot.currentModel == nil)
        #expect(snapshot.capacity == nil)
        #expect(snapshot.localEndpoint == nil)
        #expect(snapshot.version == "unknown")
        #expect(snapshot.providerName == "Gaj’s Mac")
        // Paused snapshots are content-stable across polls (publish-on-change).
        #expect(snapshot.sampledAt == snapshot.sourceUpdatedAt)
    }

    @Test("A dead process is stale while managed and paused after unload")
    func deadPidUsesLaunchdOwnership() {
        let managed = DaemonSnapshotMapping.map(
            inputs(state: freshState(), alive: false, loaded: true)
        )
        #expect(managed.runState == .stale)
        #expect(managed.pid == nil)
        #expect(managed.uptime == nil)

        let stopped = DaemonSnapshotMapping.map(
            inputs(state: freshState(), alive: false, loaded: false)
        )
        #expect(stopped.runState == .paused)
        #expect(stopped.pid == nil)
        #expect(stopped.uptime == nil)
    }

    @Test("Fresh idle daemon → online with full detail")
    func freshIdleMapsOnline() {
        let snapshot = DaemonSnapshotMapping.map(inputs(state: freshState(), alive: true))
        #expect(snapshot.runState == .online)
        #expect(snapshot.pid == 4242)
        #expect(snapshot.version == "0.8.5")
        #expect(snapshot.warmModels.map(\.id) == ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
        #expect(snapshot.currentModel?.id == "gpt-oss-20b")
        #expect(snapshot.trust.state == .unknown)
        #expect(snapshot.activity.tokensGenerated == 98_231)
        #expect(snapshot.capacity?.gpuMemoryCacheGB == 3.2)
        #expect(snapshot.system?.thermalState == "nominal")
        #expect(snapshot.connectivity?.reconnectCount == 1)
        #expect(snapshot.lastProblem == nil)
        #expect(snapshot.uptime == 3_598)
        // Uptime/freshness track the source file, not the sampling clock.
        #expect(snapshot.sampledAt == snapshot.sourceUpdatedAt)
        #expect(snapshot.freshnessAge == 0)
    }

    @Test("Active inference → serving")
    func inferenceMapsServing() {
        let snapshot = DaemonSnapshotMapping.map(inputs(state: freshState(inferenceActive: true), alive: true))
        #expect(snapshot.runState == .serving)
        #expect(snapshot.isServing)
    }

    @Test("Daemon schedule posture maps into live availability")
    func scheduleMapsIntoAvailability() {
        let nextChange = referenceNow.timeIntervalSince1970 + 3_600
        let active = freshState(schedule: .init(
            mode: "scheduled-active",
            summary: "Mon-Fri 09:00-17:00",
            nextChangeAtEpoch: nextChange
        ))
        let activeSnapshot = DaemonSnapshotMapping.map(inputs(state: active, alive: true))

        #expect(activeSnapshot.runState == .online)
        #expect(activeSnapshot.availability.state == .scheduledActive)
        #expect(activeSnapshot.availability.summary == "Mon-Fri 09:00-17:00")
        #expect(activeSnapshot.availability.nextChangeAt == Date(timeIntervalSince1970: nextChange))
    }

    @Test("Outside scheduled hours is not reported as manually paused")
    func scheduledOffMapsWithoutLiveProcess() {
        let nextChange = referenceNow.timeIntervalSince1970 + 3_600
        let state = scheduledOffState()
        let snapshot = DaemonSnapshotMapping.map(inputs(state: state, alive: false))

        #expect(snapshot.runState == .scheduledOff)
        #expect(!snapshot.isRunning)
        #expect(snapshot.availability.state == .scheduledOff)
        #expect(snapshot.availability.summary.contains("Mon-Fri 09:00-17:00"))
        #expect(snapshot.availability.nextChangeAt == Date(timeIntervalSince1970: nextChange))
    }

    @Test("A future off boundary remains authoritative while its heartbeat ages")
    func scheduledOffBoundaryOutranksGenericStaleness() {
        let state = scheduledOffState(age: 120)
        for (alive, loaded) in [(true, true), (true, false), (false, true)] {
            let snapshot = DaemonSnapshotMapping.map(
                inputs(state: state, alive: alive, loaded: loaded)
            )

            #expect(snapshot.runState == .scheduledOff)
            #expect(snapshot.availability.state == .scheduledOff)
            #expect(snapshot.availability.nextChangeAt
                == referenceNow.addingTimeInterval(3_600))
            #expect(snapshot.lastProblem == nil)
            #expect(snapshot.currentModel == nil)
            #expect(snapshot.capacity == nil)
        }
    }

    @Test("An unloaded service cannot inherit retained scheduled-off posture")
    func stoppedServiceMapsPaused() {
        for age in [2.0, 120.0] {
            let snapshot = DaemonSnapshotMapping.map(
                inputs(
                    state: scheduledOffState(age: age),
                    alive: false,
                    loaded: false
                )
            )

            #expect(snapshot.runState == .paused)
            #expect(snapshot.availability.state == .paused)
        }
    }

    @Test("A missing off boundary expires only after the heartbeat age limit")
    func scheduledOffWithoutBoundaryUsesFreshness() {
        let atLimit = DaemonSnapshotMapping.map(
            inputs(
                state: scheduledOffState(age: 90, nextChangeOffset: nil),
                alive: true
            )
        )
        #expect(atLimit.runState == .scheduledOff)
        #expect(atLimit.availability.state == .scheduledOff)

        let expired = DaemonSnapshotMapping.map(
            inputs(
                state: scheduledOffState(age: 90.001, nextChangeOffset: nil),
                alive: true
            )
        )
        #expect(expired.runState == .stale)
        #expect(expired.availability.state == .unknown)
        #expect(expired.availability.nextChangeAt == nil)
    }

    @Test("Schedule boundaries expire at equality for active and off postures")
    func expiredScheduleBoundaryNeedsFreshState() {
        for mode in ["scheduled-active", "scheduled-off"] {
            for offset in [-1.0, 0.0] {
                let state = freshState(schedule: .init(
                    mode: mode,
                    summary: "Mon-Fri 09:00-17:00",
                    nextChangeAtEpoch: referenceNow.timeIntervalSince1970 + offset
                ))
                let snapshot = DaemonSnapshotMapping.map(
                    inputs(state: state, alive: true)
                )

                #expect(snapshot.runState == .stale)
                #expect(snapshot.availability.state == .unknown)
                #expect(snapshot.availability.nextChangeAt == nil)
                #expect(snapshot.currentModel == nil)

                let managedDown = DaemonSnapshotMapping.map(
                    inputs(state: state, alive: false, loaded: true)
                )
                #expect(managedDown.runState == .stale)
                #expect(managedDown.availability.state == .unknown)

                let manuallyStopped = DaemonSnapshotMapping.map(
                    inputs(state: state, alive: false, loaded: false)
                )
                #expect(manuallyStopped.runState == .paused)
                #expect(manuallyStopped.availability.state == .paused)
            }
        }
    }

    @Test("A loaded job with a dead process is failed, not manually paused")
    func loadedDeadProviderMapsStale() {
        let active = freshState(schedule: .init(
            mode: "scheduled-active",
            summary: "Mon-Fri 09:00-17:00",
            nextChangeAtEpoch: referenceNow.timeIntervalSince1970 + 3_600
        ))
        let always = freshState(schedule: .init(
            mode: "always",
            summary: "always available",
            nextChangeAtEpoch: nil
        ))

        for state in [active, always] {
            let snapshot = DaemonSnapshotMapping.map(
                inputs(state: state, alive: false, loaded: true)
            )
            #expect(snapshot.runState == .stale)
            #expect(snapshot.lastProblem?.id == "provider-state-stale")
        }
    }

    @Test("Old writes → stale run state + critical problem")
    func staleMapsStale() {
        var state = freshState()
        state.writtenAt = referenceNow.timeIntervalSince1970 - 120
        let snapshot = DaemonSnapshotMapping.map(inputs(state: state, alive: true))
        #expect(snapshot.runState == .stale)
        #expect(snapshot.isStale)
        #expect(snapshot.lastProblem?.id == "provider-state-stale")
        #expect(snapshot.lastProblem?.severity == .critical)
        // Live-only fields are discounted, last-known identity stays.
        #expect(snapshot.capacity == nil)
        #expect(snapshot.currentModel == nil)
        #expect(snapshot.warmModels.isEmpty)
        #expect(snapshot.system == nil)
        #expect(snapshot.pid == 4242)
    }

    @Test("Failing trust statuses → attention + failed trust snapshot")
    func untrustedMapsAttention() {
        for status in ["untrusted", "offline", "denied", "failed"] {
            let trust = DaemonState.Trust(
                trustLevel: "none", status: status,
                reason: "Hardware verification is incomplete", receivedAt: referenceNow.timeIntervalSince1970 - 30)
            let snapshot = DaemonSnapshotMapping.map(inputs(state: freshState(trust: trust), alive: true))
            #expect(snapshot.runState == .attention, "\(status) should demand attention")
            #expect(snapshot.trust.state == .failed)
            #expect(snapshot.trust.reason == "Hardware verification is incomplete")
        }
    }

    @Test("Verified trust maps through with level + timestamps")
    func verifiedTrust() {
        let trust = DaemonState.Trust(
            trustLevel: "hardware", status: "verified",
            reason: "Secure Enclave and MDM verification passed",
            receivedAt: referenceNow.timeIntervalSince1970 - 60)
        let snapshot = DaemonSnapshotMapping.map(inputs(state: freshState(trust: trust), alive: true))
        #expect(snapshot.runState == .online)
        #expect(snapshot.trust.state == .verified)
        #expect(snapshot.trust.level == "hardware")
        #expect(snapshot.trust.updatedAt == referenceNow.addingTimeInterval(-60))
    }

    @Test("Hardware level without a successful coordinator status stays pending")
    func hardwareTrustRequiresSuccessfulStatus() {
        for status in ["unknown", "pending", "challenge_sent"] {
            let trust = DaemonState.Trust(
                trustLevel: "hardware",
                status: status,
                reason: "Waiting for the coordinator",
                receivedAt: referenceNow.timeIntervalSince1970 - 30
            )
            let snapshot = DaemonSnapshotMapping.map(
                inputs(state: freshState(trust: trust), alive: true)
            )

            #expect(snapshot.trust.state == .pending)
        }
    }

    @Test("Model-load attention and banner expire together after five minutes")
    func loadErrorAttention() {
        var recent = freshState()
        recent.lastModelLoadError = .init(model: "gemma-4-26b-qat-4bit", message: "insufficient memory", at: referenceNow.timeIntervalSince1970 - 60)
        let recentSnapshot = DaemonSnapshotMapping.map(inputs(state: recent, alive: true))
        #expect(recentSnapshot.runState == .attention)
        #expect(recentSnapshot.lastProblem?.id == "model-load-error")
        #expect(recentSnapshot.lastProblem?.severity == .warning)
        #expect(recentSnapshot.lastProblem?.detail.contains("gemma-4-26b-qat-4bit") == true)
        #expect(recentSnapshot.lastProblem?.recoveryTitle == "Review Mac")

        var old = freshState()
        old.lastModelLoadError = .init(model: "gemma-4-26b-qat-4bit", message: "insufficient memory", at: referenceNow.timeIntervalSince1970 - 3_600)
        let oldSnapshot = DaemonSnapshotMapping.map(inputs(state: old, alive: true))
        #expect(oldSnapshot.runState == .online)
        #expect(oldSnapshot.lastProblem == nil)

        var justInside = freshState()
        justInside.lastModelLoadError = .init(
            model: "gemma-4-26b-qat-4bit",
            message: "insufficient memory",
            at: referenceNow.timeIntervalSince1970 - 299
        )
        #expect(
            DaemonSnapshotMapping.map(inputs(state: justInside, alive: true))
                .lastProblem?.id == "model-load-error"
        )

        var atBoundary = freshState()
        atBoundary.lastModelLoadError = .init(
            model: "gemma-4-26b-qat-4bit",
            message: "insufficient memory",
            at: referenceNow.timeIntervalSince1970 - 300
        )
        let boundarySnapshot = DaemonSnapshotMapping.map(
            inputs(state: atBoundary, alive: true)
        )
        #expect(boundarySnapshot.runState == .online)
        #expect(boundarySnapshot.lastProblem == nil)
    }

    @Test("local.json maps to an endpoint only while the daemon runs")
    func endpointMapping() {
        let identity = ProcessIdentity(pid: 4242, startTimeMicros: 100)
        let info = LocalEndpointInfo(
            host: "0.0.0.0", port: 8000, apiKey: "dk-local-x",
            version: "0.8.5", pid: identity.pid,
            processIdentity: identity, updatedAt: "")
        #expect(info.baseURL == "http://127.0.0.1:8000/v1", "unspecified bind must dial loopback")

        let snapshot = DaemonSnapshotMapping.map(inputs(state: freshState(), alive: true, endpoint: info))
        #expect(snapshot.localEndpoint?.baseURL == URL(string: "http://127.0.0.1:8000/v1"))
        #expect(snapshot.localEndpoint?.requiresAuthentication == true)
        #expect(snapshot.localEndpoint?.isReachable == true)

        var reused = info
        reused.processIdentity = ProcessIdentity(
            pid: identity.pid,
            startTimeMicros: identity.startTimeMicros + 1
        )
        let untrusted = DaemonSnapshotMapping.map(
            inputs(state: freshState(), alive: true, endpoint: reused)
        )
        #expect(untrusted.localEndpoint == nil)

        let paused = DaemonSnapshotMapping.map(inputs(state: nil, alive: false, endpoint: info))
        #expect(paused.localEndpoint == nil)
    }

    @Test("Model ids become human display names")
    func displayNames() {
        #expect(DaemonSnapshotMapping.modelDisplayName("gpt-oss-20b") == "GPT OSS 20B")
        #expect(DaemonSnapshotMapping.modelDisplayName("gemma-4-26b-qat-4bit") == "Gemma 4 26B QAT 4-bit")
        #expect(DaemonSnapshotMapping.modelDisplayName("qwen3-vl-30b") == "Qwen3 VL 30B")
        #expect(DaemonSnapshotMapping.modelSummary(id: "qwen3-vl-30b").isVision)
        #expect(!DaemonSnapshotMapping.modelSummary(id: "gpt-oss-20b").isVision)
    }
}
