import Foundation

/// Private, single-request reference command. No Options/transport/serving
/// dispatch is entered; all source and arithmetic admission precedes MLX work.
struct QwenFullGenerationReferenceCLI {
    static let mode = "qwen-full-generation-reference"
    static let profileID = "registered_qwen35_9b_greedy_generation_v1"
    let directory: URL
    let tokensFile: URL
    let promptSHA256: String
    let requestID: UUID
    let stageCut: Int
    let outputCount: Int
    let stopTokenIDs: Set<Int>
    let timeoutSeconds: Int

    init(arguments: [String]) throws {
        let keys: Set<String> = ["--mode", "--model-dir", "--tokens-file", "--tokens-sha256",
            "--request-id", "--stage-cut", "--output-count", "--stop-token-ids", "--timeout-seconds"]
        guard arguments.count == keys.count * 2 else { throw ProbeError("Full generation reference requires exactly nine option pairs") }
        var fields: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard keys.contains(key), fields[key] == nil, !value.isEmpty,
                  value.utf8.count <= 4096, !value.utf8.contains(0) else {
                throw ProbeError("Unknown, repeated or oversized full-reference option")
            }
            fields[key] = value
        }
        guard fields["--mode"] == Self.mode,
              let promptSHA = fields["--tokens-sha256"], qwenStageWireIsSHA256(promptSHA),
              let id = UUID(uuidString: fields["--request-id"]!),
              fields["--request-id"] == id.uuidString.lowercased(),
              fields["--model-dir"]!.hasPrefix("/"), fields["--tokens-file"]!.hasPrefix("/") else {
            throw ProbeError("Full reference requires its namespace, absolute input paths and canonical UUID/SHA256")
        }
        let cut = try Self.integer(fields["--stage-cut"]!, range: 1...31)
        guard [4, 8, 12, 16].contains(cut) else { throw ProbeError("Full reference cut must match the serving 4|8|12|16 scope") }
        let stops = fields["--stop-token-ids"]!
        guard stops.first == "[", stops.last == "]" else { throw ProbeError("Stop IDs require a canonical integer array") }
        let interior = stops.dropFirst().dropLast()
        let values = try interior.isEmpty ? [] : interior.split(separator: ",", omittingEmptySubsequences: false)
            .map { try Self.integer(String($0), range: 0...248_319) }
        guard values.count <= 512, values == Array(Set(values)).sorted() else {
            throw ProbeError("Stop IDs must be sorted, unique and bounded")
        }
        directory = URL(fileURLWithPath: fields["--model-dir"]!, isDirectory: true)
        tokensFile = URL(fileURLWithPath: fields["--tokens-file"]!)
        promptSHA256 = promptSHA; requestID = id; stageCut = cut
        outputCount = try Self.integer(fields["--output-count"]!, range: 1...128)
        timeoutSeconds = try Self.integer(fields["--timeout-seconds"]!, range: 1...300)
        stopTokenIDs = Set(values)
    }

    func preflight(environment: [String: String], read: (URL, Int) throws -> Data) throws -> QwenFullGenerationReferencePreflight {
        let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(environment)
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen35NineB }) else {
            throw ProbeError("Registered 9B specification unavailable")
        }
        let config = try read(directory.appendingPathComponent("config.json"), 1_048_576)
        let manifest = try read(directory.appendingPathComponent("manifest.json"), 4_194_304)
        let prompt = try read(tokensFile, 65_536)
        guard !config.isEmpty, config.count <= 1_048_576, sha256(config) == specification.configurationSHA256,
              !manifest.isEmpty, manifest.count <= 4_194_304, sha256(manifest) == specification.manifestSHA256,
              !prompt.isEmpty, prompt.count <= 65_536 else { throw ProbeError("Full reference raw source/input pin or byte cap differs") }
        let source = try QwenRegistered9BLongPrefillReferenceAdmission(configuration: config,
            expectedArtifactAggregateSHA256: specification.artifactSHA256,
            promptData: prompt, expectedPromptSHA256: promptSHA256,
            request: .init(profile: .longPrefill8KV1, requestID: requestID, batchSize: 1,
                promptCount: 8192, chunkSize: 512, outputCount: 1), arithmetic: arithmetic, stageCut: stageCut)
        let profile = try QwenLayerStageGenerationProfile(identifier: Self.profileID, vocabularySize: 248_320,
            hiddenSize: specification.hidden, activationDType: "bfloat16", maximumPromptTokens: 8192,
            maximumChunkTokens: 512, maximumOutputTokens: 128, maximumContextTokens: 8320)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: requestID,
            promptTokenIDs: source.request.promptTokenIDs, chunkSize: 512, outputCount: outputCount,
            stopTokenIDs: stopTokenIDs)
        return .init(admission: try .init(source: source, request: request), manifest: manifest,
            manifestSHA256: specification.manifestSHA256)
    }

    private static func integer(_ text: String, range: ClosedRange<Int>) throws -> Int {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), String(value) == text, range.contains(value) else {
            throw ProbeError("Full reference integer is noncanonical or out of range")
        }
        return value
    }
}

struct QwenFullGenerationReferencePreflight {
    let admission: QwenGenerationReferenceAdmission
    let manifest: Data
    let manifestSHA256: String
}
