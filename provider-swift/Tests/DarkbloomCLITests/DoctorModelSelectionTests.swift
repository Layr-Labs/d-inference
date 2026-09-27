import ProviderCore
import Testing
@testable import darkbloom

@Test("doctor diagnoses a failed cold model ahead of the recently used resident slot")
func doctorPrefersFailedColdModel() {
    let state = DaemonState(
        pid: 1, version: "0.9.10", writtenAt: 100, startedAt: 50,
        currentModel: "small", warmModels: ["small"],
        advertisedModels: ["small", "qwen"],
        lastModelLoadError: .init(model: "qwen", message: "insufficient memory", at: 99),
        slots: [
            .init(model: "small", kvBackend: "contiguous"),
            .init(model: "qwen", loadError: "insufficient memory"),
        ])
    #expect(DoctorModelSelection.preferredTarget(
        state: state, stateFresh: true,
        localModelIDs: ["small", "qwen"], fallback: "small") == "qwen")
    #expect(DoctorModelSelection.isResident("small", state: state))
    #expect(!DoctorModelSelection.isResident("qwen", state: state))
    #expect(DoctorModelSelection.preferredTarget(
        state: state, stateFresh: false,
        localModelIDs: ["small", "qwen"], fallback: "small") == "small")
}
