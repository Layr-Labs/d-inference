import Foundation
import MLXLLM
import MLXLMCommon

public struct LocalMLXModelConfiguration: Equatable, Sendable {
    public let modelID: String
    public let modelDirectory: URL
    public let tokenizerDirectory: URL
    public let defaultPrompt: String
    public let extraEOSTokens: Set<String>
    public let eosTokenIds: Set<Int>

    public init(
        modelID: String? = nil,
        modelDirectory: URL,
        tokenizerDirectory: URL? = nil,
        defaultPrompt: String = "",
        extraEOSTokens: Set<String> = [],
        eosTokenIds: Set<Int> = []
    ) {
        let normalizedModelDirectory = modelDirectory.standardizedFileURL
        self.modelID = modelID ?? Self.defaultModelID(for: normalizedModelDirectory)
        self.modelDirectory = normalizedModelDirectory
        self.tokenizerDirectory = (tokenizerDirectory ?? modelDirectory).standardizedFileURL
        self.defaultPrompt = defaultPrompt
        self.extraEOSTokens = extraEOSTokens
        self.eosTokenIds = eosTokenIds
    }

    public var modelConfiguration: ModelConfiguration {
        let tokenizerSource: TokenizerSource? =
            tokenizerDirectory == modelDirectory ? nil : .directory(tokenizerDirectory)

        return ModelConfiguration(
            directory: modelDirectory,
            tokenizerSource: tokenizerSource,
            defaultPrompt: defaultPrompt,
            extraEOSTokens: extraEOSTokens,
            eosTokenIds: eosTokenIds
        )
    }

    private static func defaultModelID(for directory: URL) -> String {
        let parent = directory.deletingLastPathComponent().lastPathComponent
        let name = directory.lastPathComponent
        return parent.isEmpty ? name : "\(parent)/\(name)"
    }
}

public struct LocalMLXModelFile: Equatable, Sendable {
    public let url: URL
    public let byteCount: UInt64

    public init(url: URL, byteCount: UInt64) {
        self.url = url.standardizedFileURL
        self.byteCount = byteCount
    }
}

public struct LocalMLXModelReadinessIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case modelDirectoryMissing
        case modelDirectoryUnreadable
        case configJSONMissing
        case tokenizerDirectoryMissing
        case tokenizerDirectoryUnreadable
        case tokenizerFilesMissing
        case weightFilesMissing
    }

    public let kind: Kind
    public let path: URL
    public let detail: String?

    public init(kind: Kind, path: URL, detail: String? = nil) {
        self.kind = kind
        self.path = path.standardizedFileURL
        self.detail = detail
    }

    public var isBlocking: Bool {
        true
    }
}

public struct LocalMLXModelReadiness: Equatable, Sendable {
    public static let tokenizerFileNames: Set<String> = [
        "tokenizer.json",
        "tokenizer.model",
        "vocab.json",
    ]

    public static let weightFileExtensions: Set<String> = [
        "safetensors",
        "npz",
        "bin",
    ]

    public let configuration: LocalMLXModelConfiguration
    public let configJSON: URL?
    public let tokenizerFiles: [LocalMLXModelFile]
    public let weightFiles: [LocalMLXModelFile]
    public let issues: [LocalMLXModelReadinessIssue]

    public var canAttemptLoad: Bool {
        issues.allSatisfy { !$0.isBlocking }
    }

    public var totalWeightBytes: UInt64 {
        weightFiles.reduce(0) { $0 + $1.byteCount }
    }

    public init(
        configuration: LocalMLXModelConfiguration,
        configJSON: URL?,
        tokenizerFiles: [LocalMLXModelFile],
        weightFiles: [LocalMLXModelFile],
        issues: [LocalMLXModelReadinessIssue]
    ) {
        self.configuration = configuration
        self.configJSON = configJSON?.standardizedFileURL
        self.tokenizerFiles = tokenizerFiles
        self.weightFiles = weightFiles
        self.issues = issues
    }

    public static func inspect(
        _ configuration: LocalMLXModelConfiguration,
        fileManager: FileManager = .default
    ) -> LocalMLXModelReadiness {
        var issues: [LocalMLXModelReadinessIssue] = []

        let modelDirectory = configuration.modelDirectory
        let tokenizerDirectory = configuration.tokenizerDirectory

        guard directoryExists(modelDirectory, fileManager: fileManager) else {
            return LocalMLXModelReadiness(
                configuration: configuration,
                configJSON: nil,
                tokenizerFiles: [],
                weightFiles: [],
                issues: [
                    LocalMLXModelReadinessIssue(
                        kind: .modelDirectoryMissing,
                        path: modelDirectory
                    )
                ]
            )
        }

        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configJSON: URL? =
            fileManager.fileExists(atPath: configURL.path) ? configURL.standardizedFileURL : nil
        if configJSON == nil {
            issues.append(
                LocalMLXModelReadinessIssue(kind: .configJSONMissing, path: configURL)
            )
        }

        let weightFiles = collectFiles(
            in: modelDirectory,
            matchingExtensions: weightFileExtensions,
            fileManager: fileManager
        ) { error in
            issues.append(
                LocalMLXModelReadinessIssue(
                    kind: .modelDirectoryUnreadable,
                    path: modelDirectory,
                    detail: error.localizedDescription
                )
            )
        }
        if weightFiles.isEmpty {
            issues.append(
                LocalMLXModelReadinessIssue(kind: .weightFilesMissing, path: modelDirectory)
            )
        }

        let tokenizerFiles: [LocalMLXModelFile]
        if directoryExists(tokenizerDirectory, fileManager: fileManager) {
            tokenizerFiles = collectNamedFiles(
                in: tokenizerDirectory,
                names: tokenizerFileNames,
                fileManager: fileManager
            ) { error in
                issues.append(
                    LocalMLXModelReadinessIssue(
                        kind: .tokenizerDirectoryUnreadable,
                        path: tokenizerDirectory,
                        detail: error.localizedDescription
                    )
                )
            }
            if tokenizerFiles.isEmpty {
                issues.append(
                    LocalMLXModelReadinessIssue(
                        kind: .tokenizerFilesMissing,
                        path: tokenizerDirectory
                    )
                )
            }
        } else {
            tokenizerFiles = []
            issues.append(
                LocalMLXModelReadinessIssue(
                    kind: .tokenizerDirectoryMissing,
                    path: tokenizerDirectory
                )
            )
        }

        return LocalMLXModelReadiness(
            configuration: configuration,
            configJSON: configJSON,
            tokenizerFiles: tokenizerFiles,
            weightFiles: weightFiles,
            issues: issues
        )
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func collectNamedFiles(
        in directory: URL,
        names: Set<String>,
        fileManager: FileManager,
        onReadError: (Error) -> Void
    ) -> [LocalMLXModelFile] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            .filter { names.contains($0.lastPathComponent) }
            .compactMap { fileInfo(for: $0) }
            .sorted { $0.url.path < $1.url.path }
        } catch {
            onReadError(error)
            return []
        }
    }

    private static func collectFiles(
        in directory: URL,
        matchingExtensions extensions: Set<String>,
        fileManager: FileManager,
        onReadError: (Error) -> Void
    ) -> [LocalMLXModelFile] {
        var readError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                readError = error
                return false
            }
        ) else {
            return []
        }

        var files: [LocalMLXModelFile] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext), let file = fileInfo(for: url) else {
                continue
            }
            files.append(file)
        }

        if let error = readError {
            onReadError(error)
        }

        return files.sorted { $0.url.path < $1.url.path }
    }

    private static func fileInfo(for url: URL) -> LocalMLXModelFile? {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        else {
            return nil
        }

        return LocalMLXModelFile(url: url, byteCount: UInt64(values.fileSize ?? 0))
    }
}

public enum LocalMLXModelLoadError: Error, Equatable, LocalizedError, Sendable {
    case notReady([LocalMLXModelReadinessIssue])

    public var errorDescription: String? {
        switch self {
        case .notReady(let issues):
            let kinds = issues.map(\.kind.rawValue).joined(separator: ", ")
            return "Local MLX model is not ready to load: \(kinds)"
        }
    }
}

public struct LocalMLXModelLoader: Sendable {
    private let tokenizerLoader: any TokenizerLoader

    public init(tokenizerLoader: any TokenizerLoader) {
        self.tokenizerLoader = tokenizerLoader
    }

    public static func live() -> LocalMLXModelLoader {
        LocalMLXModelLoader(tokenizerLoader: LocalTokenizerLoader())
    }

    public func readiness(
        for configuration: LocalMLXModelConfiguration,
        fileManager: FileManager = .default
    ) -> LocalMLXModelReadiness {
        LocalMLXModelReadiness.inspect(configuration, fileManager: fileManager)
    }

    public func loadContainer(
        for configuration: LocalMLXModelConfiguration,
        fileManager: FileManager = .default
    ) async throws -> ModelContainer {
        let readiness = readiness(for: configuration, fileManager: fileManager)
        guard readiness.canAttemptLoad else {
            throw LocalMLXModelLoadError.notReady(readiness.issues)
        }

        let resolved = configuration.modelConfiguration.resolved(
            modelDirectory: configuration.modelDirectory,
            tokenizerDirectory: configuration.tokenizerDirectory
        )
        let context = try await LLMModelFactory.shared._load(
            configuration: resolved,
            tokenizerLoader: tokenizerLoader
        )
        return ModelContainer(context: context)
    }
}
