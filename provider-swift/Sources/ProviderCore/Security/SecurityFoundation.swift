import CryptoKit
import Darwin
import Foundation

// MARK: - SIP Status

public enum SIPStatus: Sendable, Equatable {
    case enabled
    case enabledWithCustomConfiguration(disabledProtections: [String])
    case disabled
    case unavailable(reason: String)
    case unrecognized(output: String)

    public var isFullyEnabled: Bool {
        self == .enabled
    }

    public var reportsEnabled: Bool {
        switch self {
        case .enabled, .enabledWithCustomConfiguration:
            return true
        case .disabled, .unavailable, .unrecognized:
            return false
        }
    }
}

public enum SIPStatusParser {
    public static func parse(_ result: SecurityCommandResult) -> SIPStatus {
        if result.terminationStatus != 0 {
            let reason = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: reason.isEmpty ? "csrutil exited with \(result.terminationStatus)" : reason)
        }
        return parse(result.stdout)
    }

    public static func parse(_ output: String) -> SIPStatus {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unrecognized(output: output)
        }

        let statusLine = trimmed
            .components(separatedBy: .newlines)
            .first { $0.localizedCaseInsensitiveContains("System Integrity Protection status:") }
            ?? trimmed.components(separatedBy: .newlines).first
            ?? trimmed

        let normalizedStatus = statusLine.lowercased()
        if normalizedStatus.contains("disabled") {
            return .disabled
        }

        if normalizedStatus.contains("enabled") {
            if normalizedStatus.contains("custom configuration") {
                return .enabledWithCustomConfiguration(
                    disabledProtections: disabledSIPProtections(in: trimmed)
                )
            }
            return .enabled
        }

        return .unrecognized(output: output)
    }

    private static func disabledSIPProtections(in output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { return nil }
            guard parts[0].localizedCaseInsensitiveCompare("System Integrity Protection status") != .orderedSame else {
                return nil
            }
            return parts[1].localizedCaseInsensitiveContains("disabled") ? parts[0] : nil
        }
    }
}

public struct SIPStatusChecker: Sendable {
    private let runner: SecurityCommandRunner

    public init(runner: SecurityCommandRunner = .live) {
        self.runner = runner
    }

    public func status() -> SIPStatus {
        do {
            return SIPStatusParser.parse(try runner.run("/usr/bin/csrutil", ["status"]))
        } catch {
            return .unavailable(reason: String(describing: error))
        }
    }

    public func isFullyEnabled() -> Bool {
        status().isFullyEnabled
    }
}

// MARK: - SHA-256 Hashing

public enum SecurityHashError: Error, CustomStringConvertible, Equatable {
    case fileNotFound(String)
    case unreadableFile(String)
    case invalidChunkSize(Int)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "file not found: \(path)"
        case .unreadableFile(let path):
            return "file is not readable: \(path)"
        case .invalidChunkSize(let chunkSize):
            return "invalid chunk size: \(chunkSize)"
        }
    }
}

public struct BinarySHA256Hasher: Sendable {
    public let chunkSize: Int

    public init(chunkSize: Int = 65_536) {
        self.chunkSize = chunkSize
    }

    public func hashData(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    public func hashFile(at url: URL) throws -> String {
        try hashFileDigest(at: url).hexString
    }

    private func hashFileDigest(at url: URL) throws -> SHA256.Digest {
        guard chunkSize > 0 else {
            throw SecurityHashError.invalidChunkSize(chunkSize)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SecurityHashError.fileNotFound(url.path)
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw SecurityHashError.unreadableFile(url.path)
        }
        defer { try? handle.close() }

        return sha256Digest(of: handle, chunkSize: chunkSize)
    }
}

// MARK: - Runtime Hash Reporting

public struct RuntimeHashReport: Sendable, Equatable {
    public let binaryHash: String?
    public let templateHashes: [String: String]

    public init(
        binaryHash: String? = nil,
        templateHashes: [String: String] = [:]
    ) {
        self.binaryHash = binaryHash
        self.templateHashes = templateHashes
    }

    public var coordinatorRuntimeHashes: RuntimeHashes {
        RuntimeHashes(templateHashes: templateHashes)
    }
}

public struct RuntimeHashReporter: @unchecked Sendable {
    private let hasher: BinarySHA256Hasher
    private let fileManager: FileManager

    public init(hasher: BinarySHA256Hasher = BinarySHA256Hasher(), fileManager: FileManager = .default) {
        self.hasher = hasher
        self.fileManager = fileManager
    }

    public func report(
        binaryURL: URL? = RuntimeHashReporter.currentExecutableURL(),
        templateDirectory: URL? = nil
    ) throws -> RuntimeHashReport {
        RuntimeHashReport(
            binaryHash: try binaryURL.map { try hasher.hashFile(at: $0) },
            templateHashes: try templateDirectory.map(templateHashes(in:)) ?? [:]
        )
    }

    public static func currentExecutableURL() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = UInt32(MAXPATHLEN)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return nil
        }
        guard let resolved = realpath(buffer, nil) else {
            return URL(fileURLWithPath: String(cString: buffer))
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func templateHashes(in directory: URL) throws -> [String: String] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return [:]
        }

        let templateURLs = try filesUnder(directory)
            .filter { $0.pathExtension == "jinja" }
            .sorted(by: { $0.path < $1.path })

        var result: [String: String] = [:]
        for url in templateURLs {
            result[url.deletingPathExtension().lastPathComponent] = try hasher.hashFile(at: url)
        }
        return result
    }

    private func filesUnder(_ directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls
    }
}
