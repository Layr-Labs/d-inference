import DarkbloomFanProtocol
import DarkbloomFanService
import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

extension FanServiceManager {
    func bundledHelperURL() throws -> URL {
        let executable = try currentExecutableURL()
        let directory = executable.deletingLastPathComponent()
        guard directory.lastPathComponent == "MacOS" else {
            throw FanServiceManagerError.helperNotBundled([
                "a signed Darkbloom.app/Contents/Helpers installation"
            ])
        }
        let contents = directory.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard app.pathExtension == "app" else {
            throw FanServiceManagerError.helperNotBundled([
                "a signed Darkbloom.app/Contents/Helpers installation"
            ])
        }
        let helper = contents.appendingPathComponent("Helpers/darkbloom-fan-helper")
        try verifyBundledApp(app: app, executable: executable, helper: helper)
        return helper
    }

    func currentExecutableURL() throws -> URL {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw FanServiceManagerError.unsafeFile("could not resolve current executable")
        }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        guard let resolved = realpath(path, nil) else {
            throw FanServiceManagerError.unsafeFile("could not canonicalize current executable")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
        #else
        return URL(fileURLWithPath: CommandLine.arguments[0])
        #endif
    }

    func verifyRegularExecutable(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
        else {
            throw FanServiceManagerError.unsafeFile(
                "fan helper is not a regular executable: \(url.path)"
            )
        }
    }

    func verifyHelperSignature(_ url: URL) throws {
        let result = FanProcessRunner.run(
            "/usr/bin/codesign",
            arguments: [
                "--verify", "--strict", "--verbose=2",
                "-R=\(FanCodeRequirements.helperRequirement())",
                url.path,
            ]
        )
        guard result.succeeded else {
            throw FanServiceManagerError.signatureFailed(result.output)
        }
    }

    func verifyBundledApp(app: URL, executable: URL, helper: URL) throws {
        let appRequirement = FanCodeRequirements.requirement(
            identifier: FanIPC.providerIdentifier,
            teamID: FanIPC.teamID
        )
        let signature = FanProcessRunner.run(
            "/usr/bin/codesign",
            arguments: [
                "--verify", "--deep", "--strict", "--verbose=2",
                "-R=\(appRequirement)", app.path,
            ]
        )
        guard signature.succeeded else {
            throw FanServiceManagerError.signatureFailed(
                "outer Darkbloom.app: \(signature.output)"
            )
        }

        let marker = app.appendingPathComponent(
            "Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
        )
        var markerMetadata = stat()
        guard lstat(marker.path, &markerMetadata) == 0,
              markerMetadata.st_mode & S_IFMT == S_IFREG,
              let markerValue = try? String(contentsOf: marker, encoding: .utf8),
              markerValue.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              let binary = try? Data(contentsOf: executable, options: [.mappedIfSafe]),
              binary.range(of: Data("darkbloom-fan-helper-v1".utf8)) != nil
        else {
            throw FanServiceManagerError.unsafeFile(
                "Darkbloom.app fan capability marker is missing or invalid"
            )
        }
        try verifyRegularExecutable(helper)
        try verifyHelperSignature(helper)
    }

    func installHelper(from source: URL) throws {
        let directory = paths.helper.deletingLastPathComponent()
        try ensureRootDirectory(directory)
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw FanServiceManagerError.unsafeFile(
                "could not open helper directory safely (errno \(errno))"
            )
        }
        defer { Darwin.close(directoryDescriptor) }

        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw FanServiceManagerError.unsafeFile(
                "could not open bundled helper safely (errno \(errno))"
            )
        }
        defer { Darwin.close(sourceDescriptor) }
        var sourceMetadata = stat()
        guard fstat(sourceDescriptor, &sourceMetadata) == 0,
              sourceMetadata.st_mode & S_IFMT == S_IFREG,
              sourceMetadata.st_size > 0,
              sourceMetadata.st_size <= 64 * 1024 * 1024
        else {
            throw FanServiceManagerError.unsafeFile(
                "bundled fan helper has unsafe metadata"
            )
        }

        let temporaryName = ".\(paths.helper.lastPathComponent).\(UUID().uuidString).tmp"
        let temporary = directory.appendingPathComponent(temporaryName)
        var temporaryDescriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o755
        )
        guard temporaryDescriptor >= 0 else {
            throw FanServiceManagerError.unsafeFile(
                "could not create helper staging file (errno \(errno))"
            )
        }
        var removeTemporary = true
        defer {
            if temporaryDescriptor >= 0 { Darwin.close(temporaryDescriptor) }
            if removeTemporary {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }
        try copy(
            from: sourceDescriptor,
            to: temporaryDescriptor,
            expectedBytes: Int(sourceMetadata.st_size)
        )
        guard fchmod(temporaryDescriptor, 0o755) == 0,
              fchown(temporaryDescriptor, 0, 0) == 0,
              fsync(temporaryDescriptor) == 0
        else {
            throw FanServiceManagerError.unsafeFile(
                "could not secure installed fan helper (errno \(errno))"
            )
        }
        Darwin.close(temporaryDescriptor)
        temporaryDescriptor = -1
        try verifyRegularExecutable(temporary)
        try verifyHelperSignature(temporary)
        // Recheck the enclosing seal after copying from the user-owned app.
        // This catches substitutions racing the initial preflight.
        let executable = try currentExecutableURL()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        try verifyBundledApp(
            app: contents.deletingLastPathComponent(),
            executable: executable,
            helper: source
        )
        guard try fileHash(source) == fileHash(temporary) else {
            throw FanServiceManagerError.unsafeFile(
                "bundled fan helper changed while it was being installed"
            )
        }
        guard renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            paths.helper.lastPathComponent
        ) == 0 else {
            throw FanServiceManagerError.unsafeFile(
                "could not atomically install fan helper (errno \(errno))"
            )
        }
        removeTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw FanServiceManagerError.unsafeFile(
                "could not sync installed helper directory (errno \(errno))"
            )
        }
        try verifyHelperSignature(paths.helper)
    }

    func writeLaunchDaemonPlist() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: FanLaunchDaemon.propertyList(paths: paths),
            format: .xml,
            options: 0
        )
        try ensureRootDirectory(paths.launchDaemonPlist.deletingLastPathComponent())
        try FanDurableFile.writeData(
            data,
            to: paths.launchDaemonPlist,
            permissions: 0o644
        )
    }

    func ensureRootDirectory(_ directory: URL) throws {
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw FanServiceManagerError.unsafeFile(
                    "could not inspect directory \(directory.path) (errno \(errno))"
                )
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } else if metadata.st_mode & S_IFMT != S_IFDIR {
            throw FanServiceManagerError.unsafeFile(
                "privileged path is not a directory: \(directory.path)"
            )
        }
        metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              chmod(directory.path, 0o755) == 0,
              chown(directory.path, 0, 0) == 0
        else {
            throw FanServiceManagerError.unsafeFile(
                "could not secure directory \(directory.path) (errno \(errno))"
            )
        }
    }

    func bootoutIfLoaded() throws {
        guard isLoaded() else { return }
        let result = FanProcessRunner.run(
            "/bin/launchctl",
            arguments: ["bootout", Self.target]
        )
        guard result.succeeded
            || result.output.contains("3:")
            || result.output.contains("could not find service")
        else {
            throw FanServiceManagerError.launchctlFailed(result.output)
        }
    }

    func bootoutWithRetries() throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try bootoutIfLoaded()
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError ?? FanServiceManagerError.launchctlFailed("bootout failed")
    }

    func restartDisabledHelperForRecovery() throws {
        try setLabelEnabled(true)
        if isLoaded() {
            let result = FanProcessRunner.run(
                "/bin/launchctl",
                arguments: ["kickstart", "-k", Self.target]
            )
            guard result.succeeded else {
                throw FanServiceManagerError.launchctlFailed(result.output)
            }
        } else {
            try bootstrap()
            try kickstart()
        }
        guard isLoaded() else {
            throw FanServiceManagerError.launchctlFailed(
                "recovery helper did not remain registered"
            )
        }
    }

    func waitForJournalClear() -> Bool {
        for _ in 0..<30 {
            if !FileManager.default.fileExists(atPath: paths.sessionJournal.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !FileManager.default.fileExists(atPath: paths.sessionJournal.path)
    }

    func setLabelEnabled(_ enabled: Bool) throws {
        let result = FanProcessRunner.run(
            "/bin/launchctl",
            arguments: [enabled ? "enable" : "disable", Self.target]
        )
        guard result.succeeded else {
            throw FanServiceManagerError.launchctlFailed(result.output)
        }
    }

    func bootstrap() throws {
        let result = FanProcessRunner.run(
            "/bin/launchctl",
            arguments: ["bootstrap", "system", paths.launchDaemonPlist.path]
        )
        guard result.succeeded
            || result.output.contains("37:")
            || result.output.contains("already loaded")
        else {
            throw FanServiceManagerError.launchctlFailed(result.output)
        }
    }

    func kickstart() throws {
        let result = FanProcessRunner.run(
            "/bin/launchctl",
            arguments: ["kickstart", Self.target]
        )
        guard result.succeeded else {
            throw FanServiceManagerError.launchctlFailed(result.output)
        }
    }

    private func fileHash(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private func copy(
        from source: Int32,
        to destination: Int32,
        expectedBytes: Int
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var copied = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(source, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw FanServiceManagerError.unsafeFile(
                    "could not read bundled fan helper (errno \(errno))"
                )
            }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { rawBuffer in
                    Darwin.write(
                        destination,
                        rawBuffer.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw FanServiceManagerError.unsafeFile(
                        "could not write staged fan helper (errno \(errno))"
                    )
                }
                offset += written
                copied += written
            }
        }
        guard copied == expectedBytes else {
            throw FanServiceManagerError.unsafeFile(
                "bundled fan helper changed size while being copied"
            )
        }
    }
}
