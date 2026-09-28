import Foundation

@main struct ShortPairLoadCheckMain {
    static func main() throws {
        let data = try FileHandle.standardInput.read(upToCount: 4 * 1_048_576 + 1) ?? Data()
        guard (1...(4 * 1_048_576)).contains(data.count) else { throw ProbeError("Short pair fixture stdin exceeds its bound") }
        let inputs = try JSONDecoder().decode(QwenObservedFixtureInputs.self, from: data)
        let result = try checkQwenDenseShortPairLoading(inputs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var dataOut = try encoder.encode(result); dataOut.append(10)
        try FileHandle.standardOutput.write(contentsOf: dataOut)
    }
}
