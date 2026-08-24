import Foundation

/// Versioned input corpus for deterministic Qwen prefill-quality experiments.
///
/// Corpus files are intentionally small, human-reviewable, and text-only. The
/// benchmark applies the loaded checkpoint's chat template; prompts must not
/// contain pre-rendered control tokens.
public struct QwenQualityCorpus: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Case: Codable, Equatable, Sendable {
        public let id: String
        public let category: String
        public let prompt: String

        public init(id: String, category: String, prompt: String) {
            self.id = id
            self.category = category
            self.prompt = prompt
        }
    }

    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let description: String
    public let license: String
    public let provenance: String
    public let cases: [Case]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String,
        version: String,
        description: String,
        license: String,
        provenance: String,
        cases: [Case]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.description = description
        self.license = license
        self.provenance = provenance
        self.cases = cases
    }
}

public struct LoadedQwenQualityCorpus: Sendable {
    public let corpus: QwenQualityCorpus
    public let path: String
    public let sha256: String

    public init(corpus: QwenQualityCorpus, path: String, sha256: String) {
        self.corpus = corpus
        self.path = path
        self.sha256 = sha256
    }
}

public enum QwenQualityCorpusLoader {
    public static let maximumFileBytes = 4 * 1024 * 1024
    public static let maximumCases = 512
    public static let maximumPromptBytes = 256 * 1024

    private static let corpusFields: Set<String> = [
        "schemaVersion", "id", "version", "description", "license", "provenance", "cases",
    ]
    private static let caseFields: Set<String> = ["id", "category", "prompt"]

    public static func load(from url: URL) throws -> LoadedQwenQualityCorpus {
        let resolved = url.standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw QwenQualityCorpusError.notRegularFile(resolved.path)
        }
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw QwenQualityCorpusError.emptyFile
        }
        guard fileSize <= maximumFileBytes else {
            throw QwenQualityCorpusError.fileTooLarge(
                actual: fileSize, maximum: maximumFileBytes)
        }

        let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
        try rejectUnknownFields(in: data)
        let corpus: QwenQualityCorpus
        do {
            corpus = try JSONDecoder().decode(QwenQualityCorpus.self, from: data)
        } catch {
            throw QwenQualityCorpusError.invalidJSON(String(describing: error))
        }
        try validate(corpus)
        return LoadedQwenQualityCorpus(
            corpus: corpus,
            path: resolved.path,
            sha256: MTPBenchmarkDigest.sha256(data))
    }

    public static func validate(_ corpus: QwenQualityCorpus) throws {
        guard corpus.schemaVersion == QwenQualityCorpus.currentSchemaVersion else {
            throw QwenQualityCorpusError.unsupportedSchemaVersion(corpus.schemaVersion)
        }
        try validateIdentifier(corpus.id, field: "id")
        try validateIdentifier(corpus.version, field: "version")
        try validateMetadata(corpus.description, field: "description", maximumBytes: 4_096)
        try validateMetadata(corpus.license, field: "license", maximumBytes: 128)
        try validateMetadata(corpus.provenance, field: "provenance", maximumBytes: 4_096)

        guard !corpus.cases.isEmpty else {
            throw QwenQualityCorpusError.noCases
        }
        guard corpus.cases.count <= maximumCases else {
            throw QwenQualityCorpusError.tooManyCases(
                actual: corpus.cases.count, maximum: maximumCases)
        }

        var identifiers: Set<String> = []
        for (index, entry) in corpus.cases.enumerated() {
            try validateIdentifier(entry.id, field: "cases[\(index)].id")
            try validateIdentifier(entry.category, field: "cases[\(index)].category")
            guard identifiers.insert(entry.id).inserted else {
                throw QwenQualityCorpusError.duplicateCaseID(entry.id)
            }
            let trimmed = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw QwenQualityCorpusError.emptyPrompt(caseID: entry.id)
            }
            let byteCount = entry.prompt.utf8.count
            guard byteCount <= maximumPromptBytes else {
                throw QwenQualityCorpusError.promptTooLarge(
                    caseID: entry.id, actual: byteCount, maximum: maximumPromptBytes)
            }
            guard !containsDisallowedControlCharacter(entry.prompt) else {
                throw QwenQualityCorpusError.controlCharacter(caseID: entry.id)
            }
        }
    }

    private static func rejectUnknownFields(in data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QwenQualityCorpusError.invalidJSON(String(describing: error))
        }
        guard let root = object as? [String: Any] else {
            throw QwenQualityCorpusError.invalidJSON("top-level value must be an object")
        }
        let unknownRoot = Set(root.keys).subtracting(corpusFields).sorted()
        guard unknownRoot.isEmpty else {
            throw QwenQualityCorpusError.unknownFields(path: "$", fields: unknownRoot)
        }
        guard let cases = root["cases"] as? [Any] else {
            // JSONDecoder supplies the more specific missing/type error.
            return
        }
        for (index, value) in cases.enumerated() {
            guard let entry = value as? [String: Any] else { continue }
            let unknown = Set(entry.keys).subtracting(caseFields).sorted()
            guard unknown.isEmpty else {
                throw QwenQualityCorpusError.unknownFields(
                    path: "$.cases[\(index)]", fields: unknown)
            }
        }
    }

    private static func validateMetadata(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QwenQualityCorpusError.emptyField(field)
        }
        guard value.utf8.count <= maximumBytes else {
            throw QwenQualityCorpusError.fieldTooLarge(
                field: field, actual: value.utf8.count, maximum: maximumBytes)
        }
        guard !containsDisallowedControlCharacter(value) else {
            throw QwenQualityCorpusError.controlCharacter(caseID: field)
        }
    }

    private static func validateIdentifier(_ value: String, field: String) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128,
              isASCIIAlphaNumeric(bytes[0]),
              bytes.allSatisfy({
                  isASCIIAlphaNumeric($0) || $0 == 0x2d || $0 == 0x2e || $0 == 0x5f
              })
        else {
            throw QwenQualityCorpusError.invalidIdentifier(field: field, value: value)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5a).contains(byte)
            || (0x61 ... 0x7a).contains(byte)
    }

    private static func containsDisallowedControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20
                && scalar.value != 0x09
                && scalar.value != 0x0a
                && scalar.value != 0x0d
        }
    }
}

public enum QwenQualityCorpusError: Error, Equatable, CustomStringConvertible {
    case notRegularFile(String)
    case emptyFile
    case fileTooLarge(actual: Int, maximum: Int)
    case invalidJSON(String)
    case unknownFields(path: String, fields: [String])
    case unsupportedSchemaVersion(Int)
    case emptyField(String)
    case fieldTooLarge(field: String, actual: Int, maximum: Int)
    case invalidIdentifier(field: String, value: String)
    case noCases
    case tooManyCases(actual: Int, maximum: Int)
    case duplicateCaseID(String)
    case emptyPrompt(caseID: String)
    case promptTooLarge(caseID: String, actual: Int, maximum: Int)
    case controlCharacter(caseID: String)

    public var description: String {
        switch self {
        case .notRegularFile(let path):
            return "quality corpus is not a regular file: \(path)"
        case .emptyFile:
            return "quality corpus is empty"
        case .fileTooLarge(let actual, let maximum):
            return "quality corpus is \(actual) bytes; maximum is \(maximum)"
        case .invalidJSON(let message):
            return "quality corpus JSON is invalid: \(message)"
        case .unknownFields(let path, let fields):
            return "quality corpus has unknown field(s) at \(path): \(fields.joined(separator: ", "))"
        case .unsupportedSchemaVersion(let version):
            return "quality corpus schemaVersion \(version) is unsupported; expected "
                + "\(QwenQualityCorpus.currentSchemaVersion)"
        case .emptyField(let field):
            return "quality corpus field '\(field)' must not be empty"
        case .fieldTooLarge(let field, let actual, let maximum):
            return "quality corpus field '\(field)' is \(actual) bytes; maximum is \(maximum)"
        case .invalidIdentifier(let field, let value):
            return "quality corpus \(field) '\(value)' must be 1...128 ASCII letters, "
                + "digits, '.', '_', or '-', beginning with a letter or digit"
        case .noCases:
            return "quality corpus must contain at least one case"
        case .tooManyCases(let actual, let maximum):
            return "quality corpus has \(actual) cases; maximum is \(maximum)"
        case .duplicateCaseID(let id):
            return "quality corpus contains duplicate case id '\(id)'"
        case .emptyPrompt(let caseID):
            return "quality corpus case '\(caseID)' has an empty prompt"
        case .promptTooLarge(let caseID, let actual, let maximum):
            return "quality corpus case '\(caseID)' prompt is \(actual) bytes; maximum is \(maximum)"
        case .controlCharacter(let caseID):
            return "quality corpus value '\(caseID)' contains a disallowed control character"
        }
    }
}
