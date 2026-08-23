import Darwin
import Foundation
import SandboxRuntime

struct LumeRuntimeWorkspace: Sendable {
    static let supportDirectoryName = ".darkbloom-runtime"
    static let operationsDirectoryName = "operations"
    static let commandJournalDirectoryName = "command-journal"

    let storageDirectory: URL
    let supportDirectory: URL
    let configurationHome: URL
    let cacheDirectory: URL
    let locksDirectory: URL
    let operationsDirectory: URL
    let commandJournalDirectory: URL

    init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
        supportDirectory = storageDirectory.appendingPathComponent(
            Self.supportDirectoryName,
            isDirectory: true
        )
        configurationHome = supportDirectory.appendingPathComponent(
            "config",
            isDirectory: true
        )
        cacheDirectory = supportDirectory.appendingPathComponent(
            "cache",
            isDirectory: true
        )
        locksDirectory = supportDirectory.appendingPathComponent(
            "locks",
            isDirectory: true
        )
        operationsDirectory = supportDirectory.appendingPathComponent(
            Self.operationsDirectoryName,
            isDirectory: true
        )
        commandJournalDirectory = supportDirectory.appendingPathComponent(
            Self.commandJournalDirectoryName,
            isDirectory: true
        )
    }

    func prepare() throws {
        try Self.ensurePrivateDirectory(storageDirectory)
        try Self.ensurePrivateDirectory(supportDirectory)
        try Self.ensurePrivateDirectory(configurationHome)
        try Self.ensurePrivateDirectory(cacheDirectory)
        try Self.ensurePrivateDirectory(locksDirectory)
        try Self.ensurePrivateDirectory(operationsDirectory)
        try Self.ensurePrivateDirectory(commandJournalDirectory)
        try Self.writeConfiguration(
            configurationHome: configurationHome,
            homeDirectory: storageDirectory,
            cacheDirectory: cacheDirectory
        )
    }

    var environment: [String: String] {
        [
            "LUME_HOME": supportDirectory.path,
            "LUME_LOG_LEVEL": "error",
            "LUME_TELEMETRY_ENABLED": "false",
            "NO_COLOR": "1",
            "XDG_CACHE_HOME": cacheDirectory.path,
            "XDG_CONFIG_HOME": configurationHome.path,
        ]
    }

    func makeCreationWorkspace(name: String) throws -> LumeCreationWorkspace {
        try prepare()

        let destination = storageDirectory.appendingPathComponent(
            name,
            isDirectory: true
        )
        guard !Self.pathExists(destination) else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) has an unrecognized storage entry"
            )
        }

        let operationDirectory = operationsDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let operationConfigurationHome = operationDirectory.appendingPathComponent(
            "config",
            isDirectory: true
        )
        let temporaryVMDirectory = operationDirectory.appendingPathComponent(
            "temporary-vms",
            isDirectory: true
        )
        let operationCacheDirectory = operationDirectory.appendingPathComponent(
            "cache",
            isDirectory: true
        )

        do {
            try Self.ensurePrivateDirectory(
                operationDirectory,
                withIntermediateDirectories: false
            )
            try Self.ensurePrivateDirectory(operationConfigurationHome)
            try Self.ensurePrivateDirectory(temporaryVMDirectory)
            try Self.ensurePrivateDirectory(operationCacheDirectory)
            try Self.writeConfiguration(
                configurationHome: operationConfigurationHome,
                homeDirectory: temporaryVMDirectory,
                cacheDirectory: operationCacheDirectory
            )
        } catch {
            try? FileManager.default.removeItem(at: operationDirectory)
            throw error
        }

        return LumeCreationWorkspace(
            destination: destination,
            operationDirectory: operationDirectory,
            environment: [
                "LUME_HOME": operationDirectory.path,
                "LUME_LOG_LEVEL": "error",
                "LUME_TELEMETRY_ENABLED": "false",
                "NO_COLOR": "1",
                "XDG_CACHE_HOME": operationCacheDirectory.path,
                "XDG_CONFIG_HOME": operationConfigurationHome.path,
            ]
        )
    }

    static func pathExists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    private static func ensurePrivateDirectory(
        _ url: URL,
        withIntermediateDirectories: Bool = true
    ) throws {
        if !pathExists(url) {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: withIntermediateDirectories,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw SandboxRuntimeError.unsupported(
                    "failed to create private Lume runtime directory \(url.path)"
                )
            }
        }

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0,
              FileManager.default.isWritableFile(atPath: url.path)
        else {
            throw SandboxRuntimeError.unsupported(
                "Lume runtime directory is not a private writable directory: \(url.path)"
            )
        }
    }

    private static func writeConfiguration(
        configurationHome: URL,
        homeDirectory: URL,
        cacheDirectory: URL
    ) throws {
        let paths = [homeDirectory.path, cacheDirectory.path]
        guard paths.allSatisfy({
            !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\"")
        }) else {
            throw SandboxRuntimeError.unsupported(
                "Lume runtime paths contain unsupported configuration characters"
            )
        }

        let lumeConfigurationDirectory = configurationHome.appendingPathComponent(
            "lume",
            isDirectory: true
        )
        try ensurePrivateDirectory(lumeConfigurationDirectory)
        let configuration = """
        defaultLocationName: "home"
        cacheDirectory: "\(cacheDirectory.path)"
        cachingEnabled: false
        telemetryEnabled: false

        vmLocations:
          - name: "home"
            path: "\(homeDirectory.path)"
        """
        let destination = lumeConfigurationDirectory.appendingPathComponent(
            "config.yaml",
            isDirectory: false
        )
        do {
            try Data(configuration.utf8).write(
                to: destination,
                options: .atomic
            )
            guard chmod(destination.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            throw SandboxRuntimeError.unsupported(
                "failed to write isolated Lume runtime configuration"
            )
        }
    }
}

struct LumeCreationWorkspace: Sendable {
    let destination: URL
    let operationDirectory: URL
    let environment: [String: String]

    func removeScratch() async throws {
        try await removeAndVerify([operationDirectory])
    }

    func removeAllArtifacts() async throws {
        try await removeAndVerify([destination, operationDirectory])
    }

    private func removeAndVerify(_ urls: [URL]) async throws {
        var lastError: Error?
        for attempt in 0..<20 {
            lastError = nil
            for url in urls where LumeRuntimeWorkspace.pathExists(url) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    lastError = error
                }
            }
            if urls.allSatisfy({ !LumeRuntimeWorkspace.pathExists($0) }) {
                return
            }
            if attempt < 19 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw SandboxRuntimeError.unsupported(
            "failed to remove Lume creation artifacts: \(String(describing: lastError))"
        )
    }
}
