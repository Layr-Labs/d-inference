import Foundation

/// Private, single-request reference command. No Options/transport/serving
/// dispatch is entered; all source and arithmetic admission precedes MLX work.
struct QwenFullGenerationReferenceCLI {
    static let mode = "qwen-registered-full-generation-reference"
    let definition: QwenResidentModelDefinition
    let directory: URL
    let tokensFile: URL
    let promptSHA256: String
    let requestID: UUID
    let stageCut: Int
    let promptCount: Int
    let chunkSize: Int
    let outputCount: Int
    let stopTokenIDs: Set<Int>
    let timeoutSeconds: Int

    init(arguments: [String]) throws {
        let keys: Set<String> = ["--mode", "--model-dir", "--tokens-file", "--tokens-sha256",
            "--request-id", "--stage-cut", "--output-count", "--stop-token-ids", "--timeout-seconds",
            "--registered-dense-profile", "--prompt-count", "--chunk-size"]
        guard arguments.count == keys.count * 2 else { throw ProbeError("Registered generation reference requires exactly twelve option pairs") }
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
              let model = QwenRegisteredDenseModel(rawValue: fields["--registered-dense-profile"]!),
              let promptSHA = fields["--tokens-sha256"], qwenStageWireIsSHA256(promptSHA),
              let id = UUID(uuidString: fields["--request-id"]!),
              fields["--request-id"] == id.uuidString.lowercased(),
              fields["--model-dir"]!.hasPrefix("/"), fields["--tokens-file"]!.hasPrefix("/") else {
            throw ProbeError("Full reference requires its namespace, absolute input paths and canonical UUID/SHA256")
        }
        let definition = try QwenResidentModelDefinition(model: model)
        let cut = try Self.integer(fields["--stage-cut"]!, range: 1...(definition.specification.layers - 1))
        guard definition.supportedCuts.contains(cut) else { throw ProbeError("Full reference cut differs from its selected registered model") }
        let stops = fields["--stop-token-ids"]!
        guard stops.first == "[", stops.last == "]" else { throw ProbeError("Stop IDs require a canonical integer array") }
        let interior = stops.dropFirst().dropLast()
        let values = try interior.isEmpty ? [] : interior.split(separator: ",", omittingEmptySubsequences: false)
            .map { try Self.integer(String($0), range: 0...248_319) }
        guard values.count <= 256, values == Array(Set(values)).sorted() else {
            throw ProbeError("Stop IDs must be sorted, unique and bounded")
        }
        self.definition = definition
        directory = URL(fileURLWithPath: fields["--model-dir"]!, isDirectory: true)
        tokensFile = URL(fileURLWithPath: fields["--tokens-file"]!)
        promptSHA256 = promptSHA; requestID = id; stageCut = cut
        promptCount = try Self.integer(fields["--prompt-count"]!, range: 1...8192)
        chunkSize = try Self.integer(fields["--chunk-size"]!, range: 1...512)
        outputCount = try Self.integer(fields["--output-count"]!, range: 1...128)
        timeoutSeconds = try Self.integer(fields["--timeout-seconds"]!, range: 1...300)
        stopTokenIDs = Set(values)
    }

    func preflight(environment: [String: String], read: (URL, Int) throws -> Data) throws -> QwenFullGenerationReferencePreflight {
        let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(environment)
        let specification = definition.specification
        let config = try read(directory.appendingPathComponent("config.json"), 1_048_576)
        let manifest = try read(directory.appendingPathComponent("manifest.json"), 4_194_304)
        let prompt = try read(tokensFile, 65_536)
        guard !config.isEmpty, config.count <= 1_048_576, sha256(config) == specification.configurationSHA256,
              !manifest.isEmpty, manifest.count <= 4_194_304, sha256(manifest) == specification.manifestSHA256,
              !prompt.isEmpty, prompt.count <= 65_536 else { throw ProbeError("Full reference raw source/input pin or byte cap differs") }
        let source = try QwenRegisteredGenerationReferenceSource(definition: definition,
            configuration: config, manifest: manifest, promptData: prompt,
            expectedPromptSHA256: promptSHA256, promptCount: promptCount, requestID: requestID,
            stageCut: stageCut, chunkSize: chunkSize, outputCount: outputCount,
            stopTokenIDs: stopTokenIDs, arithmetic: arithmetic)
        return .init(admission: try .init(source: source, request: source.request), manifest: manifest,
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
