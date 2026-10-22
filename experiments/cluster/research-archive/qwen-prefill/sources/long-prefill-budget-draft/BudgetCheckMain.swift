import Foundation

/// Standalone Foundation-only test entry point, not part of the inference CLI.
/// Root owns compilation/execution. Read at most 1 MiB plus one overflow byte.
@main
enum BudgetCheckMain {
    static func main() throws {
        guard CommandLine.arguments.count == 1 else {
            throw QwenLongPrefillBudgetError.invalid("Budget harness takes retained config on stdin, no arguments")
        }
        var data = Data()
        let limit = 1_048_576
        while data.count <= limit {
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, limit + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw QwenLongPrefillBudgetError.invalid("Budget fixture config exceeds 1 MiB") }
        let result = try checkQwenLongPrefillBudget(configuration: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(result))
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
