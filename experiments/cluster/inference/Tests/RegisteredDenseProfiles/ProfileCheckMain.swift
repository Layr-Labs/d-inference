import Foundation

/// Standalone CPU harness only. The root supplies one bounded retained-fixture
/// JSON on stdin; no hardcoded host/path, subprocess, model or native dependency.
@main struct QwenDenseProfileCheckMain {
    static func main() throws {
        let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
        guard !data.isEmpty, data.count <= 1_048_576 else { throw QwenDenseProfileError("Fixture stdin exceeds1MiB") }
        let inputs = try JSONDecoder().decode(QwenDenseProfileFixtureInputs.self, from: data)
        let result = try checkQwenRegisteredDenseProfiles(inputs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(result); encoded.append(10)
        try FileHandle.standardOutput.write(contentsOf: encoded)
    }
}
