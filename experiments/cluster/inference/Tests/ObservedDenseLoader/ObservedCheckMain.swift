import Foundation

/// Root-only standalone Foundation fixture. Input is the already frozen CPU
/// metadata fixture, never a model directory. This draft has not been compiled.
@main struct QwenDenseObservedCheckMain {
    static func main() throws {
        let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
        guard !data.isEmpty, data.count <= 1_048_576 else { throw ProbeError("Fixture stdin exceeds 1 MiB") }
        let inputs = try JSONDecoder().decode(QwenObservedFixtureInputs.self, from: data)
        var checks = QwenObservedFixtureChecks()
        try checkObservedLegacy(&checks)
        try checkObservedRegisteredSources(inputs, &checks)
        try checkObservedStages(inputs, &checks)
        try checkObservedManifestPin(&checks)
        try checkObservedCheckpointConstructor(&checks)
        guard checks.accepted.count == 22, checks.rejected.count == 104 else {
            throw ProbeError("Observed fixture case count changed: \(checks.accepted.count)/\(checks.rejected.count)")
        }
        let result = QwenObservedCheckResult(accepted: checks.accepted, rejected: checks.rejected)
        var encoded = try canonicalJSONData(result); encoded.append(10)
        try FileHandle.standardOutput.write(contentsOf: encoded)
    }
}
