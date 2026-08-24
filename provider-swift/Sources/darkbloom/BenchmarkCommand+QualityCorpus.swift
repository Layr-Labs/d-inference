import ArgumentParser
import Foundation
import ProviderBenchmark
import ProviderCore

extension Benchmark {
    func runQwenQualityCorpus(
        modelID: String,
        modelDirectory: URL,
        corpusPath: String,
        hardware: HardwareInfo
    ) async throws {
        let corpusURL = resolvedQualityPath(corpusPath)
        let baselineURL = qualityBaselineReport.map { resolvedQualityPath($0) }
        let outputURL = qualityOutput.map { resolvedQualityPath($0) }

        if outputURL == corpusURL || (outputURL != nil && outputURL == baselineURL) {
            printError(
                "--quality-output must not overwrite the input corpus or baseline report")
            throw ExitCode.failure
        }

        do {
            let report = try await QwenQualityCorpusBenchmark.run(
                modelID: modelID,
                modelDirectory: modelDirectory,
                corpusURL: corpusURL,
                maximumTokens:
                    qualityMaxTokens ?? QwenQualityCorpusBenchmark.defaultMaximumTokens,
                runLabel:
                    qualityRunLabel ?? QwenQualityCorpusBenchmark.defaultRunLabel,
                baselineReportURL: baselineURL,
                kvBackend: try resolvedKVBackendSelection(),
                hardware: hardware)
            let json = try report.jsonString()
            if let outputURL {
                try Data(json.utf8).write(to: outputURL, options: .atomic)
                FileHandle.standardError.write(
                    Data("[quality-corpus] wrote \(outputURL.path)\n".utf8))
            } else {
                print(json)
            }
        } catch {
            printError("quality corpus benchmark failed: \(error)")
            throw ExitCode.failure
        }
    }

    private func resolvedQualityPath(_ path: String) -> URL {
        URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .absoluteURL.standardizedFileURL
    }
}
