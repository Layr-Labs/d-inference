import Foundation

/// Four pure SHA vectors only. Full cohort admission uses the real adapter target.
@main struct ReadinessMaterialCheckMain {
    static func main() throws {
        let count = try checkQwenLongPrefillReadinessMaterialVectors()
        guard count == 4 else { throw ProbeError("Readiness material vector count changed") }
        struct Result: Encodable {
            let kind = "qwen_long_prefill_readiness_material_vectors", cpuOnly = true
            let passedVectors = 4, nativeExchangeExecuted = false
            let fullCohortAdmissionFixturesExecuted = false
        }
        var data = try JSONEncoder().encode(Result()); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
