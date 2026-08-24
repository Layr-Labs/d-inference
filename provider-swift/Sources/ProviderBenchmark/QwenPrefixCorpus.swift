import Foundation

/// Human-reviewable synthetic prose used to construct exact token-prefix
/// workloads. The harness tokenizes these texts with the loaded checkpoint,
/// then joins at explicit token boundaries so requested overlap is measured,
/// not inferred from character counts.
public struct QwenPrefixCorpus: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Suffix: Codable, Equatable, Sendable {
        public let id: String
        public let text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let description: String
    public let license: String
    public let provenance: String
    public let sharedPrefix: String
    public let suffixes: [Suffix]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String,
        version: String,
        description: String,
        license: String,
        provenance: String,
        sharedPrefix: String,
        suffixes: [Suffix]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.description = description
        self.license = license
        self.provenance = provenance
        self.sharedPrefix = sharedPrefix
        self.suffixes = suffixes
    }
}

public struct LoadedQwenPrefixCorpus: Sendable {
    public let corpus: QwenPrefixCorpus
    public let path: String
    public let sha256: String

    public init(corpus: QwenPrefixCorpus, path: String, sha256: String) {
        self.corpus = corpus
        self.path = path
        self.sha256 = sha256
    }
}

public enum QwenPrefixCorpusLoader {
    public static let maximumFileBytes = 4 * 1024 * 1024
    public static let minimumSuffixes = 5
    public static let maximumSuffixes = 64
    public static let maximumTextBytes = 512 * 1024

    private static let corpusFields: Set<String> = [
        "schemaVersion", "id", "version", "description", "license", "provenance",
        "sharedPrefix", "suffixes",
    ]
    private static let suffixFields: Set<String> = ["id", "text"]

    public static func load(from url: URL) throws -> LoadedQwenPrefixCorpus {
        let resolved = url.standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw QwenPrefixCorpusError.notRegularFile(resolved.path)
        }
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw QwenPrefixCorpusError.emptyFile
        }
        guard fileSize <= maximumFileBytes else {
            throw QwenPrefixCorpusError.fileTooLarge(
                actual: fileSize, maximum: maximumFileBytes)
        }

        let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw QwenPrefixCorpusError.emptyFile }
        guard data.count <= maximumFileBytes else {
            throw QwenPrefixCorpusError.fileTooLarge(
                actual: data.count, maximum: maximumFileBytes)
        }
        try rejectUnknownFields(in: data)

        let corpus: QwenPrefixCorpus
        do {
            corpus = try JSONDecoder().decode(QwenPrefixCorpus.self, from: data)
        } catch {
            throw QwenPrefixCorpusError.invalidJSON(String(describing: error))
        }
        try validate(corpus)
        return LoadedQwenPrefixCorpus(
            corpus: corpus,
            path: resolved.path,
            sha256: MTPBenchmarkDigest.sha256(data))
    }

    public static func validate(_ corpus: QwenPrefixCorpus) throws {
        guard corpus.schemaVersion == QwenPrefixCorpus.currentSchemaVersion else {
            throw QwenPrefixCorpusError.unsupportedSchemaVersion(corpus.schemaVersion)
        }
        try validateIdentifier(corpus.id, field: "id")
        try validateIdentifier(corpus.version, field: "version")
        try validateText(corpus.description, field: "description", maximumBytes: 4_096)
        try validateText(corpus.license, field: "license", maximumBytes: 128)
        try validateText(corpus.provenance, field: "provenance", maximumBytes: 4_096)
        try validateText(
            corpus.sharedPrefix, field: "sharedPrefix", maximumBytes: maximumTextBytes)
        guard (minimumSuffixes ... maximumSuffixes).contains(corpus.suffixes.count) else {
            throw QwenPrefixCorpusError.invalidSuffixCount(
                actual: corpus.suffixes.count,
                minimum: minimumSuffixes,
                maximum: maximumSuffixes)
        }

        var identifiers: Set<String> = []
        for (index, suffix) in corpus.suffixes.enumerated() {
            try validateIdentifier(suffix.id, field: "suffixes[\(index)].id")
            guard identifiers.insert(suffix.id).inserted else {
                throw QwenPrefixCorpusError.duplicateSuffixID(suffix.id)
            }
            try validateText(
                suffix.text,
                field: "suffixes[\(index)].text",
                maximumBytes: maximumTextBytes)
        }
    }

    private static func rejectUnknownFields(in data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QwenPrefixCorpusError.invalidJSON(String(describing: error))
        }
        guard let root = object as? [String: Any] else {
            throw QwenPrefixCorpusError.invalidJSON("top-level value must be an object")
        }
        let unknownRoot = Set(root.keys).subtracting(corpusFields).sorted()
        guard unknownRoot.isEmpty else {
            throw QwenPrefixCorpusError.unknownFields(path: "$", fields: unknownRoot)
        }
        guard let suffixes = root["suffixes"] as? [Any] else { return }
        for (index, value) in suffixes.enumerated() {
            guard let suffix = value as? [String: Any] else { continue }
            let unknown = Set(suffix.keys).subtracting(suffixFields).sorted()
            guard unknown.isEmpty else {
                throw QwenPrefixCorpusError.unknownFields(
                    path: "$.suffixes[\(index)]", fields: unknown)
            }
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
            throw QwenPrefixCorpusError.invalidIdentifier(field: field, value: value)
        }
    }

    private static func validateText(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QwenPrefixCorpusError.emptyField(field)
        }
        guard value.utf8.count <= maximumBytes else {
            throw QwenPrefixCorpusError.fieldTooLarge(
                field: field, actual: value.utf8.count, maximum: maximumBytes)
        }
        guard !value.unicodeScalars.contains(where: {
            $0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0a && $0.value != 0x0d
        }) else {
            throw QwenPrefixCorpusError.controlCharacter(field)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5a).contains(byte)
            || (0x61 ... 0x7a).contains(byte)
    }
}

public enum QwenPrefixCorpusError: Error, Equatable, CustomStringConvertible {
    case notRegularFile(String)
    case emptyFile
    case fileTooLarge(actual: Int, maximum: Int)
    case invalidJSON(String)
    case unknownFields(path: String, fields: [String])
    case unsupportedSchemaVersion(Int)
    case emptyField(String)
    case fieldTooLarge(field: String, actual: Int, maximum: Int)
    case controlCharacter(String)
    case invalidIdentifier(field: String, value: String)
    case invalidSuffixCount(actual: Int, minimum: Int, maximum: Int)
    case duplicateSuffixID(String)

    public var description: String {
        switch self {
        case .notRegularFile(let path):
            return "prefix corpus is not a regular file: \(path)"
        case .emptyFile:
            return "prefix corpus is empty"
        case .fileTooLarge(let actual, let maximum):
            return "prefix corpus is \(actual) bytes; maximum is \(maximum)"
        case .invalidJSON(let message):
            return "prefix corpus JSON is invalid: \(message)"
        case .unknownFields(let path, let fields):
            return "prefix corpus has unknown field(s) at \(path): "
                + fields.joined(separator: ", ")
        case .unsupportedSchemaVersion(let version):
            return "prefix corpus schemaVersion \(version) is unsupported; expected "
                + "\(QwenPrefixCorpus.currentSchemaVersion)"
        case .emptyField(let field):
            return "prefix corpus field '\(field)' must not be empty"
        case .fieldTooLarge(let field, let actual, let maximum):
            return "prefix corpus field '\(field)' is \(actual) bytes; maximum is \(maximum)"
        case .controlCharacter(let field):
            return "prefix corpus field '\(field)' contains a disallowed control character"
        case .invalidIdentifier(let field, let value):
            return "prefix corpus \(field) '\(value)' must be 1...128 ASCII letters, "
                + "digits, '.', '_', or '-', beginning with a letter or digit"
        case .invalidSuffixCount(let actual, let minimum, let maximum):
            return "prefix corpus contains \(actual) suffixes; expected \(minimum)...\(maximum)"
        case .duplicateSuffixID(let id):
            return "prefix corpus contains duplicate suffix id '\(id)'"
        }
    }
}
