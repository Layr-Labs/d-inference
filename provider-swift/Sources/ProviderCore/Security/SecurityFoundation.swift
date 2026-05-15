import CryptoKit
import Darwin
import Foundation

@_silgen_name("ptrace")
private func providerCorePtrace(
    _ request: CInt,
    _ pid: pid_t,
    _ addr: UnsafeMutableRawPointer?,
    _ data: CInt
) -> CInt

// MARK: - Command Running

public struct SecurityCommandResult: Sendable, Equatable {
    public let terminationStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(terminationStatus: Int32, stdout: String = "", stderr: String = "") {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct SecurityCommandRunner: @unchecked Sendable {
    public var run: (_ executablePath: String, _ arguments: [String]) throws -> SecurityCommandResult

    public init(
        run: @escaping (_ executablePath: String, _ arguments: [String]) throws -> SecurityCommandResult
    ) {
        self.run = run
    }

    public static let live = SecurityCommandRunner { executablePath, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        return SecurityCommandResult(
            terminationStatus: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

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
        hexString(for: SHA256.hash(data: data))
    }

    public func hashFile(at url: URL) throws -> String {
        try hexString(for: hashFileDigest(at: url))
    }

    public func hashFilesSorted(_ urls: [URL]) throws -> String {
        var finalHasher = SHA256()
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let digest = try hashFileDigest(at: url)
            finalHasher.update(data: Data(digest))
        }
        return hexString(for: finalHasher.finalize())
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

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    private func hexString<D: Sequence>(for bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Runtime Hash Reporting

public struct RuntimeHashReport: Sendable, Equatable {
    public let binaryHash: String?
    public let pythonHash: String?
    public let runtimeHash: String?
    public let templateHashes: [String: String]

    public init(
        binaryHash: String? = nil,
        pythonHash: String? = nil,
        runtimeHash: String? = nil,
        templateHashes: [String: String] = [:]
    ) {
        self.binaryHash = binaryHash
        self.pythonHash = pythonHash
        self.runtimeHash = runtimeHash
        self.templateHashes = templateHashes
    }

    public var coordinatorRuntimeHashes: RuntimeHashes {
        RuntimeHashes(
            pythonHash: pythonHash,
            runtimeHash: runtimeHash,
            templateHashes: templateHashes
        )
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
        runtimeDirectories: [URL] = [],
        templateDirectory: URL? = nil
    ) throws -> RuntimeHashReport {
        RuntimeHashReport(
            binaryHash: try binaryURL.map { try hasher.hashFile(at: $0) },
            pythonHash: nil,
            runtimeHash: try runtimeDirectories.isEmpty ? nil : hasher.hashFilesSorted(runtimeFiles(in: runtimeDirectories)),
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

    private func runtimeFiles(in directories: [URL]) throws -> [URL] {
        try directories.flatMap { directory in
            try filesUnder(directory).filter { url in
                url.lastPathComponent != ".DS_Store"
                    && url.pathExtension != "pyc"
                    && !url.pathComponents.contains("__pycache__")
            }
        }
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
            if values.isDirectory == true, url.lastPathComponent == "__pycache__" {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls
    }
}

// MARK: - Environment Scrubbing

public struct EnvironmentVariableScrub: Sendable, Equatable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

public struct EnvironmentScrubPlan: Sendable, Equatable {
    public let removals: [EnvironmentVariableScrub]

    public init(removals: [EnvironmentVariableScrub]) {
        self.removals = removals
    }

    public var variableNames: [String] {
        removals.map(\.name).sorted()
    }

    public var isEmpty: Bool {
        removals.isEmpty
    }
}

public struct EnvironmentScrubPlanner: Sendable {
    public let dangerousVariables: [String: String]

    public init(dangerousVariables: [String: String] = EnvironmentScrubPlanner.defaultDangerousVariables) {
        self.dangerousVariables = dangerousVariables
    }

    public func plan(for environment: [String: String] = ProcessInfo.processInfo.environment) -> EnvironmentScrubPlan {
        let removals = dangerousVariables.keys
            .filter { environment[$0] != nil }
            .sorted()
            .map { EnvironmentVariableScrub(name: $0, reason: dangerousVariables[$0] ?? "unsafe provider environment") }
        return EnvironmentScrubPlan(removals: removals)
    }

    public func apply(
        to environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) }
    ) -> EnvironmentScrubPlan {
        let scrubPlan = plan(for: environment)
        for removal in scrubPlan.removals {
            unset(removal.name)
        }
        return scrubPlan
    }

    public static let defaultDangerousVariables: [String: String] = [
        "CFNETWORK_DIAGNOSTICS": "enables verbose networking diagnostics",
        "DYLD_FRAMEWORK_PATH": "can redirect framework loading",
        "DYLD_INSERT_LIBRARIES": "can inject code into the provider process",
        "DYLD_LIBRARY_PATH": "can redirect dynamic library loading",
        "LD_PRELOAD": "can inject code into child processes",
        "MallocErrorAbort": "changes allocator behavior during sensitive work",
        "MallocGuardEdges": "changes allocator layout and diagnostics",
        "MallocLogFile": "can write allocator activity to disk",
        "MallocScribble": "changes allocator behavior during sensitive work",
        "MallocStackLogging": "can retain allocation backtraces for inspection",
        "MallocStackLoggingNoCompact": "can retain allocation backtraces for inspection",
        "NSZombieEnabled": "keeps Objective-C objects alive for debugging",
        "OBJC_DEBUG_POOL_ALLOCATION": "enables Objective-C allocation diagnostics",
        "PYTHONDONTWRITEBYTECODE": "legacy Python runtime control must not leak into child processes",
        "PYTHONHOME": "legacy Python runtime path override",
        "PYTHONIOENCODING": "legacy Python runtime IO override",
        "PYTHONPATH": "legacy Python import path override",
        "PYTHONSTARTUP": "legacy Python startup hook",
    ]
}

// MARK: - PT_DENY_ATTACH

public struct PtraceClient: @unchecked Sendable {
    public var ptrace: (_ request: CInt, _ pid: pid_t, _ addr: UnsafeMutableRawPointer?, _ data: CInt) -> CInt
    public var lastErrno: () -> CInt

    public init(
        ptrace: @escaping (_ request: CInt, _ pid: pid_t, _ addr: UnsafeMutableRawPointer?, _ data: CInt) -> CInt,
        lastErrno: @escaping () -> CInt
    ) {
        self.ptrace = ptrace
        self.lastErrno = lastErrno
    }

    public static let live = PtraceClient(
        ptrace: { request, pid, addr, data in
            providerCorePtrace(request, pid, addr, data)
        },
        lastErrno: { errno }
    )
}

public enum DebugAttachmentProtectionError: Error, CustomStringConvertible, Equatable {
    case denyAttachFailed(errno: CInt, message: String)

    public var description: String {
        switch self {
        case .denyAttachFailed(let code, let message):
            return "PT_DENY_ATTACH failed with errno \(code): \(message)"
        }
    }
}

public struct DebugAttachmentProtector: Sendable {
    public static let ptDenyAttachRequest: CInt = 31

    private let client: PtraceClient
    private let shouldInvokePtrace: Bool

    public init(client: PtraceClient = .live, shouldInvokePtrace: Bool = true) {
        self.client = client
        self.shouldInvokePtrace = shouldInvokePtrace
    }

    public static var disabledForTests: DebugAttachmentProtector {
        DebugAttachmentProtector(
            client: PtraceClient(ptrace: { _, _, _, _ in 0 }, lastErrno: { 0 }),
            shouldInvokePtrace: false
        )
    }

    @discardableResult
    public func denyDebuggerAttachment() throws -> Bool {
        guard shouldInvokePtrace else {
            return false
        }

        let result = client.ptrace(Self.ptDenyAttachRequest, 0, nil, 0)
        guard result == 0 else {
            let code = client.lastErrno()
            throw DebugAttachmentProtectionError.denyAttachFailed(
                errno: code,
                message: String(cString: strerror(code))
            )
        }
        return true
    }
}
