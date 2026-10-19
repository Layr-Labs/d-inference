import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

// These checks print to standard output, so they run in a child process (an
// exit test) that the parent observes.

private func text(_ bytes: [UInt8]?) -> String {
    String(decoding: bytes ?? [], as: UTF8.self)
}

@Suite("Root command and table output")
struct RootCommandOutputTests {
    @Test("running the bare root command asks for help")
    func bareRootRequestsHelp() async {
        await #expect(processExitsWith: .success) {
            var root = try Darkbloom.parse([])
            do {
                try await root.run()
            } catch is CleanExit {
                exit(0)
            }
            exit(1)
        }
    }

    @Test("the model table aligns columns and formats sizes and parameter counts")
    func modelTableAndJSON() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            printModelTable([
                ModelInfo(
                    id: "fixture/large", modelType: "gpt_oss", parameters: 7_000_000_000, quantization: "4bit",
                    sizeBytes: 4_294_967_296, estimatedMemoryGb: 5.5),
                ModelInfo(
                    id: "fixture/small", parameters: 350_000_000, sizeBytes: 536_870_912, estimatedMemoryGb: 0.5),
                ModelInfo(
                    id: "fixture/tiny", modelType: "gemma4", parameters: 999, quantization: "8bit",
                    sizeBytes: 1024, estimatedMemoryGb: 1),
                ModelInfo(id: "fixture/unknown", sizeBytes: 3 * 1_073_741_824, estimatedMemoryGb: 3),
            ])
            try printJSON(HashOutput(model: "fixture/large", weightHash: "abc123"))
            exit(0)
        }
        let lines = text(result?.standardOutputContent).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        try #require(lines.count >= 10)
        func tokens(_ line: String) -> [String] { line.split(separator: " ").map(String.init) }

        #expect(tokens(lines[0]) == ["ID", "TYPE", "QUANT", "PARAMS", "SIZE", "EST", "MEM"])
        #expect(lines[1].allSatisfy { $0 == "-" || $0 == " " })
        #expect(lines[0].count == lines[1].count)
        #expect(tokens(lines[2]) == ["fixture/large", "gpt_oss", "4bit", "7.0B", "4.0", "GB", "5.5", "GB"])
        #expect(tokens(lines[3]) == ["fixture/small", "-", "-", "350.0M", "512.0", "MB", "0.5", "GB"])
        #expect(tokens(lines[4]) == ["fixture/tiny", "gemma4", "8bit", "999", "0.0", "MB", "1.0", "GB"])
        #expect(tokens(lines[5]) == ["fixture/unknown", "-", "-", "-", "3.0", "GB", "3.0", "GB"])
        // Every column starts at the same offset on every row.
        let typeColumn = lines[0].range(of: "TYPE")?.lowerBound.utf16Offset(in: lines[0])
        #expect(typeColumn != nil)
        #expect(lines[2].range(of: "gpt_oss")?.lowerBound.utf16Offset(in: lines[2]) == typeColumn)
        #expect(lines[4].range(of: "gemma4")?.lowerBound.utf16Offset(in: lines[4]) == typeColumn)

        let json = lines[6...].joined(separator: "\n")
        #expect(json.contains("\"model\" : \"fixture\\/large\""))
        #expect(json.contains("\"weightHash\" : \"abc123\""))
    }
}
