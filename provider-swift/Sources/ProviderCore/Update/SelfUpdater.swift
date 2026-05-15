import Foundation
import CryptoKit

/// Release information returned by the coordinator.
public struct ReleaseInfo: Sendable {
    public let version: String
    public let platform: String
    public let url: String
    public let bundleHash: String
    public let binaryHash: String?
    public let metallibHash: String?

    public init(
        version: String,
        platform: String,
        url: String,
        bundleHash: String,
        binaryHash: String? = nil,
        metallibHash: String? = nil
    ) {
        self.version = version
        self.platform = platform
        self.url = url
        self.bundleHash = bundleHash
        self.binaryHash = binaryHash
        self.metallibHash = metallibHash
    }

    public var sha256: String {
        bundleHash
    }
}

/// Result of an update check.
public enum UpdateCheckResult: Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(current: String, latest: ReleaseInfo)
    case checkFailed(reason: String)
}

/// Result of an update attempt.
public enum UpdateResult: Sendable {
    case updated(from: String, to: String)
    case alreadyUpToDate(version: String)
    case downloadFailed(reason: String)
    case hashMismatch(expected: String, got: String)
    case replaceFailed(reason: String)
}

/// Self-updater that checks the coordinator for new releases and applies updates.
public struct SelfUpdater: Sendable {

    private let coordinatorBaseURL: String

    public init(coordinatorBaseURL: String) {
        // Convert WebSocket URL to HTTP if needed
        var base = coordinatorBaseURL
        if base.hasPrefix("ws://") {
            base = "http://" + base.dropFirst("ws://".count)
        } else if base.hasPrefix("wss://") {
            base = "https://" + base.dropFirst("wss://".count)
        }
        // Strip trailing path components (e.g. /ws/provider)
        if let url = URL(string: base), let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            base = "\(scheme)://\(host)\(port)"
        }
        self.coordinatorBaseURL = base
    }

    // MARK: - Version Check

    /// Check the coordinator for the latest release.
    public func checkForUpdate() async -> UpdateCheckResult {
        let currentVersion = ProviderCore.version
        let endpoint = "\(coordinatorBaseURL)/v1/releases/latest?platform=macos-arm64"

        guard let url = URL(string: endpoint) else {
            return .checkFailed(reason: "invalid coordinator URL: \(endpoint)")
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .checkFailed(reason: "unexpected response type")
            }

            guard httpResponse.statusCode == 200 else {
                return .checkFailed(
                    reason: "coordinator returned HTTP \(httpResponse.statusCode)"
                )
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .checkFailed(reason: "invalid JSON response")
            }

            guard let version = json["version"] as? String,
                  let platform = json["platform"] as? String,
                  let downloadURL = json["url"] as? String
            else {
                return .checkFailed(reason: "missing required fields in release response")
            }
            guard let bundleHash = (json["bundle_hash"] as? String)
                    ?? (json["sha256"] as? String)
                    ?? (json["binary_hash"] as? String)
            else {
                return .checkFailed(reason: "missing release hash field")
            }

            let release = ReleaseInfo(
                version: version,
                platform: platform,
                url: downloadURL,
                bundleHash: bundleHash,
                binaryHash: json["binary_hash"] as? String,
                metallibHash: json["metallib_hash"] as? String
            )

            if isNewer(latest: version, current: currentVersion) {
                return .updateAvailable(current: currentVersion, latest: release)
            } else {
                return .upToDate(currentVersion: currentVersion)
            }
        } catch {
            return .checkFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Download and Verify

    /// Download the release bundle and verify its SHA-256 hash.
    public func downloadAndVerify(release: ReleaseInfo) async -> Result<URL, UpdateError> {
        guard let downloadURL = URL(string: release.url) else {
            return .failure(.invalidURL(release.url))
        }

        do {
            let (tempFileURL, response) = try await URLSession.shared.download(from: downloadURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return .failure(.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }

            // Verify SHA-256
            let fileData = try Data(contentsOf: tempFileURL)
            let digest = SHA256.hash(data: fileData)
            let computedHash = digest.map { String(format: "%02x", $0) }.joined()

            guard computedHash == release.bundleHash.lowercased() else {
                try? FileManager.default.removeItem(at: tempFileURL)
                return .failure(.hashMismatch(expected: release.bundleHash, got: computedHash))
            }

            return .success(tempFileURL)
        } catch {
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    // MARK: - Install Bundle

    /// Install a verified release bundle next to the running executable.
    ///
    /// Release artifacts are tarballs containing `bin/darkbloom`,
    /// `bin/darkbloom-enclave`, and `bin/mlx.metallib`. Older local bundles
    /// with root-level files are accepted for developer testing.
    public func installBundle(from downloadedFile: URL, release: ReleaseInfo) -> Result<Void, UpdateError> {
        guard let executablePath = Bundle.main.executablePath else {
            return .failure(.replaceFailed("could not determine current executable path"))
        }

        let installDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        return installBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: true
        )
    }

    internal func installBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<Void, UpdateError> {
        installBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: false
        )
    }

    private func installBundle(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL,
        verifyCodeSignatures: Bool
    ) -> Result<Void, UpdateError> {
        let fm = FileManager.default
        let extractionRoot = fm.temporaryDirectory
            .appendingPathComponent("darkbloom-update-\(UUID().uuidString)", isDirectory: true)
        let backupRoot = fm.temporaryDirectory
            .appendingPathComponent("darkbloom-backup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: extractionRoot)
            try? fm.removeItem(at: backupRoot)
        }

        do {
            try fm.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            try runProcess("/usr/bin/tar", arguments: ["xzf", downloadedFile.path, "-C", extractionRoot.path])

            let darkbloom = try requiredBundleFile(
                names: ["bin/darkbloom", "darkbloom"],
                root: extractionRoot
            )
            let enclave = try requiredBundleFile(
                names: ["bin/darkbloom-enclave", "darkbloom-enclave", "bin/eigeninference-enclave", "eigeninference-enclave"],
                root: extractionRoot
            )
            let metallib = try requiredBundleFile(
                names: ["bin/mlx.metallib", "mlx.metallib"],
                root: extractionRoot
            )

            if let binaryHash = release.binaryHash {
                try verifyHash(file: darkbloom, expected: binaryHash, label: "darkbloom")
            }
            if let metallibHash = release.metallibHash {
                try verifyHash(file: metallib, expected: metallibHash, label: "mlx.metallib")
            }
            if verifyCodeSignatures {
                try verifyCodeSignature(file: darkbloom, label: "darkbloom")
                try verifyCodeSignature(file: enclave, label: "darkbloom-enclave")
            }

            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            let targets = [
                ("darkbloom", darkbloom, 0o755),
                ("darkbloom-enclave", enclave, 0o755),
                ("mlx.metallib", metallib, 0o644),
            ] as [(String, URL, Int)]

            var installed: [URL] = []
            var backups: [URL: URL] = [:]
            do {
                for (name, source, mode) in targets {
                    let destination = installDir.appendingPathComponent(name)
                    let backup = backupRoot.appendingPathComponent(name)
                    if fm.fileExists(atPath: destination.path) {
                        try fm.copyItem(at: destination, to: backup)
                        backups[destination] = backup
                        try fm.removeItem(at: destination)
                    }
                    try fm.copyItem(at: source, to: destination)
                    try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
                    installed.append(destination)
                }

                let legacyLink = installDir.appendingPathComponent("eigeninference-enclave")
                let legacyBackup = backupRoot.appendingPathComponent("eigeninference-enclave")
                if itemExistsIncludingSymlink(legacyLink) {
                    try fm.copyItem(at: legacyLink, to: legacyBackup)
                    backups[legacyLink] = legacyBackup
                    try fm.removeItem(at: legacyLink)
                }
                try fm.createSymbolicLink(atPath: legacyLink.path, withDestinationPath: "darkbloom-enclave")
                installed.append(legacyLink)
            } catch {
                let destinations = Set(installed + Array(backups.keys))
                for destination in destinations {
                    try? fm.removeItem(at: destination)
                    if let backup = backups[destination], itemExistsIncludingSymlink(backup) {
                        try? fm.copyItem(at: backup, to: destination)
                    }
                }
                throw error
            }

            return .success(())
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.replaceFailed(error.localizedDescription))
        }
    }

    // MARK: - Full Update Flow

    /// Check for updates and apply if available.
    public func update() async -> UpdateResult {
        let checkResult = await checkForUpdate()

        switch checkResult {
        case .upToDate(let version):
            return .alreadyUpToDate(version: version)

        case .checkFailed(let reason):
            return .downloadFailed(reason: "update check failed: \(reason)")

        case .updateAvailable(let current, let release):
            let downloadResult = await downloadAndVerify(release: release)

            switch downloadResult {
            case .failure(let error):
                switch error {
                case .hashMismatch(let expected, let got):
                    return .hashMismatch(expected: expected, got: got)
                case .downloadFailed(let reason):
                    return .downloadFailed(reason: reason)
                case .invalidURL(let url):
                    return .downloadFailed(reason: "invalid download URL: \(url)")
                case .replaceFailed(let reason):
                    return .replaceFailed(reason: reason)
                }

            case .success(let tempFile):
                let replaceResult = installBundle(from: tempFile, release: release)
                switch replaceResult {
                case .success:
                    return .updated(from: current, to: release.version)
                case .failure(let error):
                    switch error {
                    case .replaceFailed(let reason):
                        return .replaceFailed(reason: reason)
                    default:
                        return .replaceFailed(reason: "\(error)")
                    }
                }
            }
        }
    }

    // MARK: - Version Comparison

    /// Compare semver-style version strings. Returns true if `latest` is newer than `current`.
    ///
    /// Handles versions like "0.4.0-swift", "0.4.1", etc. The suffix after '-' is
    /// stripped for comparison (pre-release suffixes are ignored for ordering).
    internal static func isNewer(latest: String, current: String) -> Bool {
        let latestParts = parseVersion(latest)
        let currentParts = parseVersion(current)

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    private static func parseVersion(_ version: String) -> [Int] {
        // Strip pre-release suffix (e.g. "-swift", "-beta1")
        let base = version.split(separator: "-").first ?? Substring(version)
        return base.split(separator: ".").compactMap { Int($0) }
    }

    private func isNewer(latest: String, current: String) -> Bool {
        Self.isNewer(latest: latest, current: current)
    }

    private func requiredBundleFile(names: [String], root: URL) throws -> URL {
        let fm = FileManager.default
        for name in names {
            let candidate = root.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw UpdateError.replaceFailed("release bundle missing \(names[0])")
    }

    private func itemExistsIncludingSymlink(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path)
            || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func verifyHash(file: URL, expected: String, label: String) throws {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        let got = digest.map { String(format: "%02x", $0) }.joined()
        guard got == expected.lowercased() else {
            throw UpdateError.hashMismatch(expected: expected, got: "\(label): \(got)")
        }
    }

    private func verifyCodeSignature(file: URL, label: String) throws {
        #if canImport(Darwin)
        do {
            try runProcess("/usr/bin/codesign", arguments: [
                "--verify",
                "--strict",
                "--verbose=2",
                file.path,
            ])
        } catch {
            throw UpdateError.replaceFailed("\(label) code signature verification failed: \(error.localizedDescription)")
        }
        #endif
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.replaceFailed(message?.isEmpty == false ? message! : "\(executable) exited \(process.terminationStatus)")
        }
    }
}

// MARK: - Errors

public enum UpdateError: Error, Sendable {
    case invalidURL(String)
    case downloadFailed(String)
    case hashMismatch(expected: String, got: String)
    case replaceFailed(String)
}
