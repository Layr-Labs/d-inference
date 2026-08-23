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
        try Self.ensurePrivateDirectory(
            storageDirectory,
            requirePrivateParent: false
        )
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
            try Self.ensurePrivateDirectory(operationDirectory)
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
        requirePrivateParent: Bool = true
    ) throws {
        do {
            let descriptor =
                try SandboxAuthorityFileSystem.openPrivateDirectory(
                    at: url,
                    createIfMissing: true,
                    requirePrivateParent: requirePrivateParent
                )
            close(descriptor)
        } catch {
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
            let directoryDescriptor =
                try SandboxAuthorityFileSystem.openPrivateDirectory(
                    at: lumeConfigurationDirectory,
                    createIfMissing: false,
                    requirePrivateParent: true
                )
            defer { close(directoryDescriptor) }
            let descriptor =
                try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(
                    parentDescriptor: directoryDescriptor,
                    prefix: "config"
                )
            defer { close(descriptor) }
            let data = Data(configuration.utf8)
            try SandboxAuthorityFileSystem.writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                descriptor,
                maximumBytes: data.count,
                allowEmpty: false,
                expectedLinkCount: 0
            )
            if unlinkat(directoryDescriptor, destination.lastPathComponent, 0) != 0,
               errno != ENOENT
            {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let cloneStatus = destination.lastPathComponent.withCString {
                fclonefileat(
                    descriptor,
                    directoryDescriptor,
                    $0,
                    UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
                )
            }
            guard cloneStatus == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let committedDescriptor = openat(
                directoryDescriptor,
                destination.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard committedDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(committedDescriptor) }
            let committed =
                try SandboxAuthorityFileSystem.readStablePrivateFile(
                    committedDescriptor,
                    maximumBytes: data.count
                )
            guard committed == data,
                  fsync(committedDescriptor) == 0,
                  fsync(directoryDescriptor) == 0
            else {
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
