import Testing
@testable import DarkbloomApp

@Test("Preview scenarios cover each required provider presentation state")
func previewScenariosCoverRequiredStates() {
    let expected: [ProviderPreviewScenario: ProviderRunState] = [
        .online: .online,
        .serving: .serving,
        .paused: .paused,
        .scheduledActive: .online,
        .scheduledOff: .scheduledOff,
        .pausedScheduled: .paused,
        .attention: .attention,
        .stale: .stale,
    ]

    #expect(ProviderPreviewScenario.allCases.count == expected.count)
    for scenario in ProviderPreviewScenario.allCases {
        #expect(scenario.snapshot.runState == expected[scenario])
        #expect(scenario.snapshot == scenario.snapshot)
    }
}

@Test("Snapshot derived values keep metric semantics honest")
func snapshotDerivedValuesReflectRuntimeTruth() {
    let online = ProviderPreviewScenario.online.snapshot
    let serving = ProviderPreviewScenario.serving.snapshot
    let paused = ProviderPreviewScenario.paused.snapshot
    let stale = ProviderPreviewScenario.stale.snapshot

    #expect(online.uptime == 12_840)
    #expect(online.isRunning)
    #expect(!online.isServing)
    #expect(serving.isServing)
    #expect(serving.currentModel != nil)
    #expect(paused.uptime == nil)
    #expect(!paused.isRunning)
    #expect(stale.isStale)
    #expect(stale.freshnessAge == 186)
}

@Test("Scheduled preview states carry coherent boundary metadata")
func scheduledPreviewBoundariesMatchTheirState() throws {
    let active = ProviderPreviewScenario.scheduledActive.snapshot
    let off = ProviderPreviewScenario.scheduledOff.snapshot
    let activeBoundary = try #require(active.availability.nextChangeAt)
    let offBoundary = try #require(off.availability.nextChangeAt)

    #expect(active.availability.state == .scheduledActive)
    #expect(activeBoundary > active.sampledAt)
    #expect(off.availability.state == .scheduledOff)
    #expect(offBoundary > off.sampledAt)
}

@Test("Capacity includes active and cache memory without exceeding one hundred percent")
func capacityFractionIsBounded() throws {
    let capacity = try #require(ProviderPreviewScenario.online.snapshot.capacity)

    #expect(capacity.usedMemoryGB == 24.8)
    #expect(capacity.usedFraction > 0)
    #expect(capacity.usedFraction < 1)

    let overcommitted = ProviderCapacitySnapshot(
        totalMemoryGB: 16,
        gpuMemoryActiveGB: 20,
        gpuMemoryCacheGB: 4
    )
    #expect(overcommitted.usedFraction == 1)
}
