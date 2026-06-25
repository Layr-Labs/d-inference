import Foundation
import Testing
@testable import ProviderCore

@Suite("Adaptive prefill policy")
struct AdaptivePrefillPolicyTests {
    private let policy = AdaptivePrefillPolicy(
        targetChunkDurationMs: 100,
        growthSampleCount: 3,
        cooldownSampleCount: 2
    )

    @Test("initial state starts at 512")
    func initialStateStartsAt512() {
        let state = policy.initialState()
        #expect(state.currentChunkSize == 512)
        #expect(policy.proposedChunkSize(state: state) == 512)
    }

    @Test("persisted safe state seeds the current chunk")
    func persistedSafeStateSeedsCurrentChunk() {
        let persisted = AdaptivePrefillState(currentChunkSize: 2048)
        let state = policy.initialState(persisted: persisted)
        #expect(state.currentChunkSize == 2048)
        #expect(state.cleanSamplesAtCurrentSize == 0)
    }

    @Test("growth requires enough clean cold-prefill samples")
    func growthRequiresCleanSamples() {
        var state = policy.initialState()
        let clean = AdaptivePrefillSample(
            requestedChunkSize: 512,
            actualChunkSize: 512,
            durationMs: 70
        )

        var transition = policy.record(sample: clean, state: state)
        state = transition.state
        #expect(state.currentChunkSize == 512)
        #expect(state.cleanSamplesAtCurrentSize == 1)

        transition = policy.record(sample: clean, state: state)
        state = transition.state
        #expect(state.currentChunkSize == 512)
        #expect(state.cleanSamplesAtCurrentSize == 2)

        transition = policy.record(sample: clean, state: state)
        #expect(transition.changedChunkSize)
        #expect(transition.reason == .grow)
        #expect(transition.state.currentChunkSize == 1024)
    }

    @Test("capped samples do not grow the ladder")
    func cappedSamplesDoNotGrow() {
        var state = policy.initialState()
        let capped = AdaptivePrefillSample(
            requestedChunkSize: 512,
            actualChunkSize: 256,
            durationMs: 20,
            cappedByCheckpoint: true
        )

        for _ in 0..<5 {
            let transition = policy.record(sample: capped, state: state)
            state = transition.state
        }

        #expect(state.currentChunkSize == 512)
        #expect(state.cleanSamplesAtCurrentSize == 0)
    }

    @Test("slow chunks shrink immediately")
    func slowChunksShrinkImmediately() {
        let state = AdaptivePrefillState(currentChunkSize: 2048)
        let slow = AdaptivePrefillSample(
            requestedChunkSize: 2048,
            actualChunkSize: 2048,
            durationMs: 140
        )

        let transition = policy.record(sample: slow, state: state)
        #expect(transition.reason == .shrinkChunkTooSlow)
        #expect(transition.changedChunkSize)
        #expect(transition.state.currentChunkSize == 1024)
        #expect(transition.state.cooldownSamplesRemaining == 2)
    }

    @Test("memory thermal decode and resource harms shrink")
    func safetySignalsShrink() {
        let highMemory = AdaptivePrefillSample(
            requestedChunkSize: 2048,
            actualChunkSize: 2048,
            durationMs: 40,
            memorySignal: .high
        )
        let thermal = AdaptivePrefillSample(
            requestedChunkSize: 2048,
            actualChunkSize: 2048,
            durationMs: 40,
            thermalSignal: .serious
        )
        let decodeHarm = AdaptivePrefillSample(
            requestedChunkSize: 2048,
            actualChunkSize: 2048,
            durationMs: 40,
            decodeLatencyHarmed: true
        )
        let resource = AdaptivePrefillSample(
            requestedChunkSize: 2048,
            actualChunkSize: 2048,
            durationMs: 40,
            resourceError: true
        )

        #expect(policy.record(sample: highMemory, state: AdaptivePrefillState(currentChunkSize: 2048)).reason == .shrinkMemoryPressure)
        #expect(policy.record(sample: thermal, state: AdaptivePrefillState(currentChunkSize: 2048)).reason == .shrinkThermalPressure)
        #expect(policy.record(sample: decodeHarm, state: AdaptivePrefillState(currentChunkSize: 2048)).reason == .shrinkDecodeHarm)
        #expect(policy.record(sample: resource, state: AdaptivePrefillState(currentChunkSize: 2048)).reason == .shrinkResourceError)
    }

    @Test("cooldown blocks immediate regrowth after shrink")
    func cooldownBlocksRegrowth() {
        var state = AdaptivePrefillState(currentChunkSize: 1024, cooldownSamplesRemaining: 2)
        let clean = AdaptivePrefillSample(
            requestedChunkSize: 1024,
            actualChunkSize: 1024,
            durationMs: 40
        )

        for _ in 0..<2 {
            let transition = policy.record(sample: clean, state: state)
            state = transition.state
            #expect(transition.reason == .cooldown)
            #expect(state.currentChunkSize == 1024)
        }

        #expect(state.cooldownSamplesRemaining == 0)
        #expect(state.cleanSamplesAtCurrentSize == 0)
    }

    @Test("8192 is unavailable unless explicitly allowed")
    func no8192WithoutExperimentalGate() {
        let production = AdaptivePrefillPolicy(growthSampleCount: 1)
        var state = AdaptivePrefillState(currentChunkSize: 4096)
        let clean = AdaptivePrefillSample(
            requestedChunkSize: 4096,
            actualChunkSize: 4096,
            durationMs: 20
        )
        state = production.record(sample: clean, state: state).state
        #expect(state.currentChunkSize == 4096)

        let experimental = AdaptivePrefillPolicy(
            ladder: AdaptivePrefillPolicy.experimentalLadder,
            growthSampleCount: 1
        )
        state = experimental.record(sample: clean, state: AdaptivePrefillState(currentChunkSize: 4096)).state
        #expect(state.currentChunkSize == 8192)
    }

    @Test("store persists by hashed local key")
    func storePersistsState() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-prefill-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("state.json")
        let store = AdaptivePrefillStore(url: url)
        let key = AdaptivePrefillStoreKey(
            modelId: "model-a",
            weightIdentity: "weight-a",
            kvMode: "fp16",
            hardwareMemoryFingerprint: "mem-a"
        )

        try store.save(AdaptivePrefillState(currentChunkSize: 2048), key: key)

        #expect(store.load(key: key)?.currentChunkSize == 2048)
        let stored = try String(contentsOf: url)
        #expect(!stored.contains("model-a"))
    }
}
