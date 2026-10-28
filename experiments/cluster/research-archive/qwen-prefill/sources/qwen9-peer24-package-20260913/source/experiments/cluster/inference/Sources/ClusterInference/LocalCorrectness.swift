import Foundation
import CoreFoundation

/// Explicit, bounded real-artifact correctness on one host. This contract never
/// admits a persistent worker or a hardware-throughput candidate.
enum LocalCorrectness {
    static let maximumPromptTokens = 128
    static let maximumChunkSize = 32
    static let maximumOutputTokens = 4
    static let maximumCapturedValues = 1_048_576

    struct Inputs {
        let configurationData: Data
        let configurationSHA256: String
        let prompt: [Int]
        let teacher: [Int]?
    }

    static func validateOptions(_ options: Options) throws {
        guard options.localCorrectness else {
            guard options.expectedArtifactAggregateSHA256 == nil else {
                throw ProbeError("artifact-aggregate-sha256 requires local-correctness")
            }
            return
        }
        guard options.mode == .ffnTP, options.transport == .loopbackTest,
            !options.synthetic, options.modelDirectory != nil,
            options.tokensFile != nil, options.logitsFile != nil,
            options.promptCount <= maximumPromptTokens,
            options.chunkSize <= maximumChunkSize,
            options.decodeCount <= maximumOutputTokens,
            options.decodeCount == 1 || options.teacherTokensFile != nil,
            options.repeats == 1, options.warmups == 0,
            options.timeoutSeconds <= 180,
            !options.hasRoutingDiagnostic, !options.gemmaDiagnostic,
            options.gemmaBoundaryFile == nil, options.ffnBranchPrecision == .native
        else {
            throw ProbeError("local-correctness requires bounded real one-shot loopback TP: prompt<=128, chunk<=32, output<=4, one repetition, zero warmups, timeout<=180, prompt/logits files and teacher history for multiple outputs")
        }
        guard let expected = options.expectedArtifactAggregateSHA256,
            expected.utf8.count == 64,
            expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ProbeError("local-correctness requires an expected lowercase artifact aggregate SHA-256") }
    }

    /// Called before collective initialization and weight loading. Retain the
    /// parsed IDs so a changed token file cannot bypass these bounds later.
    static func preflight(_ options: Options) throws -> Inputs? {
        guard options.localCorrectness else { return nil }
        try validateOptions(options)
        let configuration = try readBoundedFile(
            options.modelDirectory!.appendingPathComponent("config.json"), maximumBytes: 1_048_576)
        let prompt = try readTokens(options.tokensFile!)
        let teacher = try options.teacherTokensFile.map {
            try readTokens($0)
        }
        let inputs = Inputs(configurationData: configuration, configurationSHA256: sha256(configuration),
                            prompt: prompt, teacher: teacher)
        try validateConfiguration(configuration, options: options, inputs: inputs)
        return inputs
    }

    static func validateConfiguration(_ data: Data, options: Options, inputs: Inputs) throws {
        guard sha256(data) == inputs.configurationSHA256 else {
            throw ProbeError("local-correctness configuration changed after preflight")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = root["model_type"] as? String,
            ["qwen3_5", "qwen3_5_text"].contains(type)
        else { throw ProbeError("local-correctness currently requires a dense Qwen model") }
        let text: [String: Any]
        if let nested = root["text_config"] {
            guard let object = nested as? [String: Any] else {
                throw ProbeError("local-correctness text_config must be an object")
            }
            text = object
        } else { text = root }
        guard text["model_type"] == nil || text["model_type"] as? String == "qwen3_5_text",
            text["num_experts"] == nil || integer(text["num_experts"]) == 0,
            let vocabulary = integer(text["vocab_size"]), vocabulary > 3,
            vocabulary <= maximumCapturedValues / options.decodeCount,
            let context = integer(text["max_position_embeddings"]),
            context >= inputs.prompt.count + options.decodeCount
        else { throw ProbeError("local-correctness requires dense Qwen metadata within capture/context limits") }
        try validateInputs(inputs, options: options, vocabularySize: vocabulary)
    }

    static func validateInputs(_ inputs: Inputs, options: Options, vocabularySize: Int) throws {
        guard !inputs.prompt.isEmpty, inputs.prompt.count == options.promptCount,
            inputs.prompt.count <= maximumPromptTokens,
            inputs.prompt.allSatisfy({ (0..<vocabularySize).contains($0) }),
            vocabularySize <= maximumCapturedValues / options.decodeCount,
            options.decodeCount == 1 || inputs.teacher != nil
        else { throw ProbeError("local-correctness actual prompt/capture exceeds its admitted bounds") }
        if let teacher = inputs.teacher {
            guard teacher.count == options.decodeCount - 1,
                teacher.allSatisfy({ (0..<vocabularySize).contains($0) }) else {
                throw ProbeError("local-correctness requires exactly the admitted teacher history")
            }
        }
    }

    private static func readBoundedFile(_ file: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ProbeError("local-correctness input file is empty or exceeds its byte limit")
        }
        return data
    }

    private static func readTokens(_ file: URL) throws -> [Int] {
        let data = try readBoundedFile(file, maximumBytes: 65_536)
        try validateWorkerJSON(data)
        return try JSONDecoder().decode([Int].self, from: data)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return number as? Int
    }
}
