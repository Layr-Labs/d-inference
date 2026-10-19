import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

// `darkbloom local` runs in a child process (an exit test): the command sets
// up process-wide logging, and the child reads a discovery folder that only it
// points at through DARKBLOOM_LOCAL_DIR.

private func text(_ bytes: [UInt8]?) -> String {
    String(decoding: bytes ?? [], as: UTF8.self)
}

@Suite("Local endpoint command")
struct LocalEndpointCommandTests {
    @Test("local reports no server, then the live endpoint with and without a key")
    func localCommandOutput() async throws {
        let result = await #expect(
            processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]
        ) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-endpoint-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)

            func run(_ arguments: [String]) async throws -> Bool {
                var command = try Local.parse(arguments)
                do {
                    try await command.run()
                    return true
                } catch let code as ExitCode where code == .failure {
                    return false
                }
            }
            func publish(apiKey: String) throws {
                try LocalEndpoint.writeInfo(LocalEndpoint.Info(
                    host: "0.0.0.0", port: 8123, apiKey: apiKey, version: "9.9.9",
                    pid: getpid(), updatedAt: "2026-01-01T00:00:00Z"))
            }

            var outcomes: [Bool] = []
            outcomes.append(try await run([]))
            outcomes.append(try await run(["--json"]))
            print("---keyed---")
            try publish(apiKey: "dk-local-fixture")
            outcomes.append(try await run([]))
            print("---open---")
            try publish(apiKey: "")
            outcomes.append(try await run([]))
            print("---json---")
            outcomes.append(try await run(["--json"]))
            print("---stale---")
            try LocalEndpoint.writeInfo(LocalEndpoint.Info(
                host: "127.0.0.1", port: 8123, apiKey: "", version: "9.9.9", pid: 0, updatedAt: ""))
            outcomes.append(try await run([]))
            try? FileManager.default.removeItem(at: directory)
            exit(outcomes == [false, false, true, true, true, false] ? 0 : 1)
        }
        let stdout = text(result?.standardOutputContent)
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.components(separatedBy: "No local server running.\nStart one with:  darkbloom start --local\n")
            .count - 1 == 2)

        let sections = stdout.components(separatedBy: "---")
        try #require(sections.count == 9)
        #expect(sections[0].hasSuffix("{}\n"))

        let keyed = sections[2]
        #expect(keyed.contains("Local (direct-mode) OpenAI endpoint\n"))
        #expect(keyed.contains("  base URL: http://127.0.0.1:8123/v1\n"))
        #expect(keyed.contains("  API key:  dk-local-fixture\n"))
        #expect(keyed.contains("  pid:      "))
        #expect(keyed.contains("  export OPENAI_BASE_URL=http://127.0.0.1:8123/v1\n"))
        #expect(keyed.contains("  export OPENAI_API_KEY=dk-local-fixture\n"))
        #expect(keyed.contains("  curl http://127.0.0.1:8123/v1/chat/completions \\\n"))
        #expect(keyed.contains("    -H 'Authorization: Bearer dk-local-fixture' \\\n"))
        #expect(keyed.contains("    -H 'Content-Type: application/json' \\\n"))

        let open = sections[4]
        #expect(open.contains("  API key:  (auth disabled)\n"))
        #expect(!open.contains("OPENAI_API_KEY"))
        #expect(!open.contains("Authorization"))

        let json = sections[6]
        #expect(json.contains("\"base_url\" : \"http:\\/\\/127.0.0.1:8123\\/v1\""))
        #expect(json.contains("\"api_key\" : \"\""))
        #expect(json.contains("\"version\" : \"9.9.9\""))

        // A record whose process is gone is treated as no server.
        #expect(sections[8] == "\n")
    }
}
