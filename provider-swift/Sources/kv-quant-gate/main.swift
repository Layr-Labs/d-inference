import ArgumentParser
import Foundation
import ProviderCore

@main
struct KVQuantGate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kv-quant-gate",
        abstract: "Run the KV quant benchmark gate."
    )

    @Option(name: .customLong("model-id"), help: "Model ID to benchmark.")
    var modelID: String

    @Option(name: .customLong("model-dir"), help: "Exact local MLX model snapshot directory. If omitted, the gate resolves --model-id from the HuggingFace cache.")
    var modelDir: String?

    @Option(name: .customLong("reference"), help: "Reference KV mode.")
    var reference = "fp16-kv"

    @Option(name: .customLong("candidate"), help: "Candidate KV quant mode.")
    var candidate = "full-v-affine4:g64:start1024"

    @Option(name: .customLong("suites"), help: "Comma-separated suites to run.")
    var suites = "perf,memory,output"

    @Option(name: .customLong("contexts"), help: "Comma-separated context lengths.")
    var contexts = "4096,8192"

    @Option(name: .customLong("decode-tokens"), help: "Decode tokens per iteration.")
    var decodeTokens = 128

    @Option(name: .customLong("iterations"), help: "Iterations per suite/context.")
    var iterations = 1

    @Option(name: .customLong("data-dir"), help: "Benchmark data directory.")
    var dataDir: String?

    @Option(name: .customLong("thresholds"), help: "Optional threshold JSON file used to mark present metrics pass/fail.")
    var thresholds: String?

    @Option(name: .customLong("out"), help: "Output path for pretty JSON. Defaults to stdout.")
    var out: String?

    @Flag(name: .customLong("allow-missing-data"), help: "Allow benchmark suites with missing data fixtures to continue.")
    var allowMissingData = false

    mutating func validate() throws {
        _ = try parseSuites(suites)
        _ = try parseContexts(contexts)
        _ = try parseCandidateMode(reference, option: "--reference")
        _ = try parseCandidateMode(candidate, option: "--candidate")

        if decodeTokens <= 0 {
            throw ValidationError("--decode-tokens must be greater than zero")
        }
        if iterations <= 0 {
            throw ValidationError("--iterations must be greater than zero")
        }
        if let modelDir, !FileManager.default.fileExists(atPath: modelDir) {
            throw ValidationError("--model-dir does not exist: \(modelDir)")
        }
        if let thresholds, !FileManager.default.fileExists(atPath: thresholds) {
            throw ValidationError("--thresholds does not exist: \(thresholds)")
        }
    }

    mutating func run() async throws {
        let config = try KVQuantGateConfig(
            modelID: modelID,
            modelDirectory: modelDir.map { URL(fileURLWithPath: $0) },
            reference: parseCandidateMode(reference, option: "--reference"),
            candidate: parseCandidateMode(candidate, option: "--candidate"),
            suites: parseSuites(suites),
            contexts: parseContexts(contexts),
            decodeTokens: decodeTokens,
            iterations: iterations,
            dataDirectory: dataDir.map { URL(fileURLWithPath: $0) },
            thresholds: thresholds.map { URL(fileURLWithPath: $0) },
            allowMissingData: allowMissingData
        )

        let report = try await KVQuantGateRunner.run(config)
        let data = try encodeReport(report)

        if let out {
            try data.write(to: URL(fileURLWithPath: out))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

private func parseSuites(_ value: String) throws -> [KVQuantSuite] {
    try splitCommaSeparated(value, option: "--suites").map { rawValue in
        guard let suite = KVQuantSuite(rawValue: rawValue) else {
            let allowed = KVQuantSuite.allCases.map(\.rawValue).joined(separator: ",")
            throw ValidationError("--suites contains unknown suite '\(rawValue)'; expected one of: \(allowed)")
        }
        return suite
    }
}

private func parseContexts(_ value: String) throws -> [Int] {
    try splitCommaSeparated(value, option: "--contexts").map { rawValue in
        guard let context = Int(rawValue), context > 0 else {
            throw ValidationError("--contexts contains invalid context length '\(rawValue)'")
        }
        return context
    }
}

private func parseCandidateMode(_ value: String, option: String) throws -> KVQuantCandidateMode {
    guard let mode = KVQuantCandidateMode(rawValue: value) else {
        throw ValidationError("\(option) contains unknown KV quant mode '\(value)'")
    }
    return mode
}

private func splitCommaSeparated(_ value: String, option: String) throws -> [String] {
    let parts = value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if parts.isEmpty {
        throw ValidationError("\(option) must contain at least one value")
    }

    return parts
}

private func encodeReport(_ report: KVQuantGateReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(report)
}
