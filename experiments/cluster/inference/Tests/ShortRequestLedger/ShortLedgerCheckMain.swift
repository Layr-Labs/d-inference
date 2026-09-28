import Foundation

/// Root-owned standalone Foundation fixture. Retained metadata arrives on stdin;
/// this harness has no native model dependency, allocator, clock or payload path.
@main struct QwenDenseShortLedgerCheckMain {
    static func main() throws {
        let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
        guard !data.isEmpty, data.count <= 1_048_576 else { throw QwenDenseProfileError("Short ledger fixture stdin exceeds1MiB") }
        let inputs = try JSONDecoder().decode(QwenDenseShortLedgerFixtureInputs.self, from: data)
        let result = try checkQwenDenseShortLedger(inputs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var output = try encoder.encode(result); output.append(10)
        try FileHandle.standardOutput.write(contentsOf: output)
    }
}
