import ArgumentParser
import Foundation
import ProviderBenchmark
import ProviderCore

extension Benchmark {
    func runQwenPrefixReuse(
        modelID: String,
        modelDirectory: URL,
        corpusPath: String,
        hardware: HardwareInfo
    ) async throws {
        let corpusURL = resolvedQwenPrefixPath(corpusPath)
        let outputURL = qwenPrefixOutput.map { resolvedQwenPrefixPath($0) }
        guard outputURL != corpusURL else {
            printError("--qwen-prefix-output must not overwrite the input corpus")
            throw ExitCode.failure
        }

        do {
            let report = try await QwenPrefixReuseBenchmark.run(
                modelID: modelID,
                modelDirectory: modelDirectory,
                corpusURL: corpusURL,
                promptTokens:
                    qwenPrefixPromptTokens ?? QwenPrefixReuseBenchmark.defaultPromptTokens,
                decodeTokens:
                    qwenPrefixDecodeTokens ?? QwenPrefixReuseBenchmark.defaultDecodeTokens,
                iterations:
                    qwenPrefixIterations ?? QwenPrefixReuseBenchmark.defaultIterations,
                kvBackend: try resolvedKVBackendSelection(),
                hardware: hardware)
            let json = try report.jsonString()
            if let outputURL {
                try Data(json.utf8).write(to: outputURL, options: .atomic)
                FileHandle.standardError.write(
                    Data("[qwen-prefix] wrote \(outputURL.path)\n".utf8))
            } else {
                print(json)
            }
        } catch {
            printError("Qwen prefix-reuse benchmark failed: \(error)")
            throw ExitCode.failure
        }
    }

    private func resolvedQwenPrefixPath(_ path: String) -> URL {
        URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .absoluteURL.standardizedFileURL
    }
}
