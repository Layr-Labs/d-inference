import ArgumentParser
import Foundation
import ProviderCore

/// `darkbloom local` — print the discovered local endpoint (URL + API key)
/// for either local-only or local-plus-network serving, with ready-to-paste
/// client examples. `--json` emits the raw discovery record for tooling.
struct Local: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "local",
        abstract: "Show the local OpenAI endpoint and API key.",
        discussion: """
        Reads ~/.darkbloom/local.json, written by `darkbloom start --local` or
        `darkbloom start --local-endpoint`.
        Point any OpenAI client at the base URL with the API key to run
        inference directly on this Mac. Local requests do not pass through the
        coordinator.
        """
    )

    @Flag(help: "Emit the raw discovery record as JSON.")
    var json = false

    mutating func run() async throws {
        Darkbloom.ensureLogging()

        // readLiveInfo() returns nil when the recorded server process is gone,
        // so a stale local.json from a Ctrl-C/crash is treated as "not running"
        // rather than advertising a dead endpoint.
        guard let info = LocalEndpoint.readLiveInfo() else {
            if json {
                print("{}")
            } else {
                printError("No local server running.")
                printError("Start one with:  darkbloom start --local")
            }
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? encoder.encode(info)) ?? Data("{}".utf8)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        print("Local OpenAI endpoint")
        print("  base URL: \(info.baseURL)")
        if info.apiKey.isEmpty {
            print("  API key:  (auth disabled)")
        } else {
            print("  API key:  \(info.apiKey)")
        }
        print("  pid:      \(info.pid)")
        print()
        print("Use it with any OpenAI client:")
        print("  export OPENAI_BASE_URL=\(info.baseURL)")
        if !info.apiKey.isEmpty {
            print("  export OPENAI_API_KEY=\(info.apiKey)")
        }
        print()
        print("  curl \(info.baseURL)/chat/completions \\")
        if !info.apiKey.isEmpty {
            print("    -H 'Authorization: Bearer \(info.apiKey)' \\")
        }
        print("    -H 'Content-Type: application/json' \\")
        print("    -d '{\"model\":\"<id>\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")
    }
}
