import Foundation

@main struct QwenDenseStageLoadCheckMain {
    static func main() throws {
        let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
        guard !data.isEmpty, data.count <= 1_048_576 else { throw ProbeError("Stage load fixture stdin exceeds1MiB") }
        let input = try JSONDecoder().decode(QwenObservedFixtureInputs.self, from: data)
        let result = try checkQwenDenseStageLoading(input)
        var encoded = try canonicalJSONData(result); encoded.append(10)
        try FileHandle.standardOutput.write(contentsOf: encoded)
    }
}
