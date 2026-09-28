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

@Test("doctor checks every cold model and shows the largest shortfall first")
func doctorDiagnosesEveryColdModel() {
    let state = DaemonState(
        pid: 1, version: "0.9.10", writtenAt: 100, startedAt: 50,
        currentModel: "small", warmModels: ["small"],
        advertisedModels: ["small", "medium", "huge"],
        slots: [.init(model: "small", kvBackend: "contiguous")])
    let options = [
        ModelFitDiagnostic.ModelOption(id: "small", weightGb: 3),
        .init(id: "medium", weightGb: 10),
        .init(id: "huge", weightGb: 30),
    ]
    let targets = DoctorModelSelection.diagnosticTargets(
        state: state, stateFresh: true, localModels: options, fallback: "small")
    #expect(targets.map(\.id) == ["huge", "medium"])
    let levels = targets.map {
        ModelFitDiagnostic.diagnose(
            modelID: $0.id, weightGb: $0.weightGb, usableGb: 14.3,
            evictionAwareWeightGb: 19, loadHeadroomGb: 6.5).level
    }
    #expect(levels == [.fail, .warn])
}
