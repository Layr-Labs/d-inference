import CryptoKit
import Foundation

public struct QualificationError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum QualificationHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The runtime's token-history convention: decimal IDs joined by commas.
    public static func tokenIDs(_ ids: [Int]) -> String {
        sha256(Data(ids.map(String.init).joined(separator: ",").utf8))
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func file(_ url: URL, maximumBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256(), total = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += chunk.count
            guard total <= maximumBytes else { throw QualificationError("File exceeds its hashing bound") }
            digest.update(data: chunk)
        }
        guard total > 0 else { throw QualificationError("File is empty") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Where the prompt token IDs came from, so an operator can read the request.
public struct QualificationPromptSource: Codable, Equatable, Sendable {
    /// `chatText`, `rawText`, `synthetic` or `tokenIDs`.
    public var kind: String
    public var description: String
    public var text: String?
    public var textSHA256: String?
    public var tokenizerSHA256: String?
    /// Set when the text's tokens were repeated and cut to an exact count.
    public var bodyTokenCount: Int?
    public var matchesArtifactChatTemplate: Bool?
    public var syntheticSeed: Int?

    public init(kind: String, description: String, text: String? = nil, textSHA256: String? = nil,
                tokenizerSHA256: String? = nil, bodyTokenCount: Int? = nil,
                matchesArtifactChatTemplate: Bool? = nil, syntheticSeed: Int? = nil) {
        self.kind = kind; self.description = description; self.text = text; self.textSHA256 = textSHA256
        self.tokenizerSHA256 = tokenizerSHA256; self.bodyTokenCount = bodyTokenCount
        self.matchesArtifactChatTemplate = matchesArtifactChatTemplate; self.syntheticSeed = syntheticSeed
    }
}

/// One greedy request, read by both the single-host reference and the pair
/// driver. The stage cut is not part of it: the same request runs at any cut.
public struct QualificationRequest: Codable, Equatable, Sendable {
    public static let currentSchema = "darkbloom_cluster_qualification_request_v1"
    public static let modelID = "registered_qwen35_9b"
    public static let profileID = "registered_qwen35_9b_greedy_generation_v1"
    public static let vocabularySize = 248_320
    public static let maximumPromptTokens = 8192
    public static let maximumChunkTokens = 512
    public static let maximumOutputTokens = 128
    public static let maximumContextTokens = 8320
    public static let supportedCuts = [4, 8, 12, 16]
    public static let maximumFileBytes = 1 << 20

    /// The registered models a request may name, the original first. This tool
    /// links no runtime, so the rows repeat the runtime's closed catalog; the
    /// worker's own description is checked against the request before a launch.
    public struct RegisteredModel: Equatable, Sendable {
        public let modelID: String
        public let profileID: String
        public let supportedCuts: [Int]
        /// What the model's arithmetic contract requires of a rank's
        /// environment beyond `PairConfiguration.arithmeticEnvironment`.
        public let additionalArithmeticEnvironment: [String: String]

        init(modelID: String, profileID: String, supportedCuts: [Int],
             additionalArithmeticEnvironment: [String: String] = [:]) {
            self.modelID = modelID; self.profileID = profileID; self.supportedCuts = supportedCuts
            self.additionalArithmeticEnvironment = additionalArithmeticEnvironment
        }
    }
    public static let registeredModels: [RegisteredModel] = [
        .init(modelID: modelID, profileID: profileID, supportedCuts: supportedCuts),
        .init(modelID: "registered_qwen38_27b", profileID: "registered_qwen38_27b_greedy_generation_v1",
              supportedCuts: Array(stride(from: 4, through: 60, by: 4))),
        .init(modelID: "registered_qwen35_35b_a3b", profileID: "registered_qwen35_35b_a3b_greedy_generation_v1",
              supportedCuts: Array(stride(from: 4, through: 36, by: 4)),
              additionalArithmeticEnvironment: ["MLX_GATHER_QMM_EXPERT_SLICES": "trust"]),
    ]
    public static func registeredModel(_ modelID: String) -> RegisteredModel? {
        registeredModels.first { $0.modelID == modelID }
    }
    /// The cuts of the model this request names; empty for an unknown model.
    public var supportedCuts: [Int] { Self.registeredModel(modelID)?.supportedCuts ?? [] }
    /// The complete arithmetic environment of a rank that runs this request's
    /// model: the common variables, then the model's own in name order.
    public var arithmeticEnvironment: [(String, String)] {
        PairConfiguration.arithmeticEnvironment
            + (Self.registeredModel(modelID)?.additionalArithmeticEnvironment ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public var schema: String
    public var requestID: String
    public var modelID: String
    public var profileID: String
    public var chunkSize: Int
    public var outputCount: Int
    public var stopTokenIDs: [Int]
    public var promptTokenIDs: [Int]
    public var promptTokenIDsSHA256: String
    public var promptSource: QualificationPromptSource

    public init(requestID: UUID, promptTokenIDs: [Int], chunkSize: Int, outputCount: Int,
                stopTokenIDs: [Int], promptSource: QualificationPromptSource,
                modelID: String = QualificationRequest.modelID) throws {
        schema = Self.currentSchema; self.requestID = requestID.uuidString.lowercased()
        guard let registered = Self.registeredModel(modelID) else {
            throw QualificationError("Request: \(modelID) is not a registered model")
        }
        self.modelID = registered.modelID; profileID = registered.profileID
        self.chunkSize = chunkSize; self.outputCount = outputCount; self.stopTokenIDs = stopTokenIDs
        self.promptTokenIDs = promptTokenIDs; promptTokenIDsSHA256 = QualificationHash.tokenIDs(promptTokenIDs)
        self.promptSource = promptSource
        try validate()
    }

    public var requestUUID: UUID { UUID(uuidString: requestID)! }

    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw QualificationError("Request: " + message) }
        }
        try require(schema == Self.currentSchema, "unknown schema")
        try require(UUID(uuidString: requestID)?.uuidString.lowercased() == requestID, "request ID must be a lowercase UUID")
        try require(Self.registeredModel(modelID)?.profileID == profileID, "the model and profile must be one registered pair")
        try require((1...Self.maximumPromptTokens).contains(promptTokenIDs.count), "prompt must have 1...8192 tokens")
        try require((1...Self.maximumChunkTokens).contains(chunkSize), "chunk size must be 1...512")
        try require((1...Self.maximumOutputTokens).contains(outputCount), "output count must be 1...128")
        try require(promptTokenIDs.count <= Self.maximumContextTokens - outputCount, "prompt plus output exceeds 8320 tokens")
        try require(promptTokenIDs.allSatisfy { (0..<Self.vocabularySize).contains($0) }, "prompt token outside the vocabulary")
        try require(stopTokenIDs.count <= 256 && stopTokenIDs == Array(Set(stopTokenIDs)).sorted()
            && stopTokenIDs.allSatisfy { (0..<Self.vocabularySize).contains($0) }, "stop IDs must be sorted, unique and in the vocabulary")
        try require(promptTokenIDsSHA256 == QualificationHash.tokenIDs(promptTokenIDs), "prompt hash differs from the prompt")
        try require(["chatText", "rawText", "synthetic", "tokenIDs"].contains(promptSource.kind), "unknown prompt source")
    }

    public static func read(_ url: URL) throws -> Self {
        let data = try QualificationFiles.read(url, maximumBytes: maximumFileBytes)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(10)
        return data
    }

    /// A fixed, documented sequence of valid token IDs for when no tokenizer is
    /// wanted: `1000 + ((seed + i) * 2654435761 mod 2^32) mod 100000`. Every ID
    /// is an ordinary vocabulary entry (1000...100999); the text is not meaningful.
    public static func syntheticPrompt(count: Int, seed: Int) -> [Int] {
        (0..<count).map { index in
            let mixed = (UInt64(truncatingIfNeeded: seed &+ index) &* 2_654_435_761) & 0xffff_ffff
            return 1000 + Int(mixed % 100_000)
        }
    }
}

public enum QualificationFiles {
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw QualificationError("File \(url.lastPathComponent) is empty or exceeds \(maximumBytes) bytes")
        }
        return data
    }

    /// Never replaces an existing file: a report is evidence of one run.
    public static func writeNew(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw QualificationError("Cannot create \(url.lastPathComponent): it exists or its directory is not writable")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
