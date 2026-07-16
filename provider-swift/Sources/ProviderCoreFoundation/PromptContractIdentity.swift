import Crypto
import Foundation

public enum PromptContractIdentity {
    public static let normalizationVersion = "darkbloom-request-normalization-v2"
    public static let rendererVersion = "swift-jinja-compatible-v1"
    public static let tokenizerVersion = "huggingface-tokenizer-json-v1"
    public static let blockHashVersion = "darkbloom-block-chain-v1"
    public static let blockSize: UInt32 = 256

    public enum Error: Swift.Error, Equatable {
        case invalidArtifact
    }

    public static func compute(files: [ManifestFile]) throws -> String {
        let artifacts = files.filter {
            $0.role == "tokenizer" || $0.role == "template" || $0.role == "config"
        }.sorted {
            if $0.role != $1.role { return $0.role < $1.role }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.sha256 < $1.sha256
        }
        guard !artifacts.isEmpty, artifacts.count <= Int(UInt32.max) else {
            throw Error.invalidArtifact
        }

        var encoded = Data()
        try appendField(Data("darkbloom.prompt-contract.v1".utf8), to: &encoded)
        appendUInt32(UInt32(artifacts.count), to: &encoded)
        for artifact in artifacts {
            guard validRelativePath(artifact.path),
                  artifact.sha256 == artifact.sha256.lowercased(),
                  let digest = Data(hex: artifact.sha256),
                  digest.count == 32
            else {
                throw Error.invalidArtifact
            }
            try appendField(Data(artifact.role.utf8), to: &encoded)
            try appendField(Data(artifact.path.utf8), to: &encoded)
            try appendField(digest, to: &encoded)
        }
        for (name, value) in [
            ("normalization", normalizationVersion),
            ("renderer", rendererVersion),
            ("tokenizer", tokenizerVersion),
            ("block_hash", blockHashVersion),
        ] {
            try appendField(Data(name.utf8), to: &encoded)
            try appendField(Data(value.utf8), to: &encoded)
        }
        try appendField(Data("block_size".utf8), to: &encoded)
        appendUInt32(blockSize, to: &encoded)
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    public static func compute(modelDirectory: URL) throws -> String {
        let root = modelDirectory.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let standaloneTemplate = root.appendingPathComponent("chat_template.jinja")
        guard let template = try? String(contentsOf: standaloneTemplate, encoding: .utf8),
              !template.contains("strftime_now"),
              TemplateRenderCheck.renderOK(at: root) == true
        else {
            throw Error.invalidArtifact
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw Error.invalidArtifact
        }
        var files: [ManifestFile] = []
        for case let entry as URL in enumerator {
            let name = entry.lastPathComponent
            guard ModelScanner.integrityFileNames.contains(name) else { continue }
            let role = ModelScanner.roleFor(filename: name)
            guard role == "tokenizer" || role == "template" || role == "config" else {
                continue
            }
            let entryPath = entry.standardizedFileURL.path
            guard entryPath.hasPrefix(rootPrefix) else { throw Error.invalidArtifact }
            let relativePath = String(entryPath.dropFirst(rootPrefix.count))
            let data = try Data(contentsOf: entry, options: [.mappedIfSafe])
            files.append(ManifestFile(
                path: relativePath,
                sizeBytes: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                role: role
            ))
        }
        let paths = Set(files.map(\.path))
        guard paths.contains("config.json"),
              paths.contains("tokenizer.json"),
              paths.contains("tokenizer_config.json")
                || paths.contains("chat_template.jinja")
                || paths.contains("chat_template.json")
        else {
            throw Error.invalidArtifact
        }
        return try compute(files: files)
    }

    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func appendField(_ value: Data, to output: inout Data) throws {
        guard value.count <= Int(UInt32.max) else { throw Error.invalidArtifact }
        appendUInt32(UInt32(value.count), to: &output)
        output.append(value)
    }

    private static func appendUInt32(_ value: UInt32, to output: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
