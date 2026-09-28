import Foundation

@main struct ConstructorProbeCheckMain {
    static func main() throws {
        let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
        guard !data.isEmpty, data.count <= 1_048_576 else { throw ProbeError("Bounded retained metadata stdin required") }
        let inputs = try JSONDecoder().decode(ConstructorProbeFixtureInput.self, from: data)
        let result = try checkConstructorProbe(inputs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var output = try encoder.encode(result); output.append(10)
        try FileHandle.standardOutput.write(contentsOf: output)
    }
}
