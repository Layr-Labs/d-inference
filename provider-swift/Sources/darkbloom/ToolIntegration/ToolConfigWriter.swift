import Darwin
import Foundation
import ProviderCore

/// Makes a planned edit to a tool's config safely: idempotent, backed up, atomic, and undoable with one command.
///
/// - Nothing is written, and no backup made, when the planned bytes equal the file's.
/// - Before a change, the file's exact bytes go to `<state>/backups/<tool>/<file name>.<yyyyMMdd'T'HHmmss'Z'>` (folder
///   0700, file 0600); the five newest of each file are kept. A failed backup means no write.
/// - The new bytes replace the file in one rename (`AtomicFile`), keeping its mode; a link (a dotfiles repo) is
///   written through and stays a link.
/// - One lock in Darkbloom's state folder serialises Darkbloom's own runs. Against the tool's own writer, the file is
///   read again just before the rename: when it changed, the edit is planned once more; twice, it is refused.
/// - A dry run plans and returns the bytes: no lock, no backup, no file.
struct ToolConfigWriter {
    enum Outcome: Equatable, Sendable {
        case unchanged(file: URL, ToolConfigSummary)
        /// A dry run's new bytes; nothing was written.
        case planned(file: URL, contents: Data, ToolConfigSummary)
        /// `backup` is nil when the file was new; `undo` is the shell command that puts the file back exactly.
        case written(file: URL, backup: URL?, undo: String, ToolConfigSummary)
        case refused(file: URL, ToolConfigRefusal)
    }

    let tool: IntegrationTool
    /// `<install dir>/integrations`.
    let stateDirectory: URL
    var keptBackups = 5
    var now: @Sendable () -> Date = { Date() }
    /// Runs once the new bytes are on disk, just before the check for another writer and the rename. A test seam.
    var beforeReplace: (URL) throws -> Void = { _ in }

    /// Larger than any tool config; a bigger file is refused rather than read.
    static let maximumFileBytes = 4 << 20
    static let lockTimeout: TimeInterval = 10

    func apply(
        to file: URL, newFileMode: mode_t, dryRun: Bool = false, plan: (Data?) -> ToolConfigPlan
    ) throws -> Outcome {
        do {
            let target = try Self.resolve(file)
            var current = try Self.read(target)
            let planned = plan(current)
            guard case .change(var bytes, var summary) = planned else { return outcome(of: planned, file) }
            if dryRun { return .planned(file: file, contents: bytes, summary) }
            return try withLock {
                var raced = 0
                while true {
                    let mode = current == nil ? newFileMode : try Self.mode(of: target)
                    let backup = try current.map { try makeBackup(of: $0, named: file.lastPathComponent) }
                    do {
                        let expected = current
                        try AtomicFile.write(bytes, to: target, mode: mode) {
                            try beforeReplace(target)
                            guard try Self.read(target) == expected else { throw ChangedDuringEdit() }
                        }
                    } catch is ChangedDuringEdit {
                        if let backup { try? FileManager.default.removeItem(at: backup) }
                        raced += 1
                        guard raced < 2 else {
                            return .refused(file: file, .file("it changed while Darkbloom was editing it; run this again"))
                        }
                        current = try Self.read(target)
                        let replanned = plan(current)
                        guard case .change(let newBytes, let newSummary) = replanned else {
                            return outcome(of: replanned, file)
                        }
                        (bytes, summary) = (newBytes, newSummary)
                        continue
                    }
                    if backup != nil { pruneBackups(named: file.lastPathComponent) }
                    let undo = backup.map { "cp \(ToolIntegration.shellQuoted($0.path)) \(ToolIntegration.shellQuoted(file.path))" }
                        ?? "rm \(ToolIntegration.shellQuoted(file.path))"
                    return .written(file: file, backup: backup, undo: undo, summary)
                }
            }
        } catch let refusal as ToolConfigRefusal {
            return .refused(file: file, refusal)
        }
    }

    private struct ChangedDuringEdit: Error {}

    private func outcome(of plan: ToolConfigPlan, _ file: URL) -> Outcome {
        switch plan {
        case .unchanged(let summary): .unchanged(file: file, summary)
        case .refused(let refusal): .refused(file: file, refusal)
        case .change(let bytes, let summary): .planned(file: file, contents: bytes, summary)
        }
    }

    // MARK: - The file

    /// The file to read and replace: `file` itself, or the file a link at `file` points to.
    private static func resolve(_ file: URL) throws -> URL {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return file }
        let target = file.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolConfigRefusal.file("it is a link to a file that doesn't exist")
        }
        return target
    }

    /// The file's bytes; nil when it doesn't exist.
    private static func read(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ToolConfigWriterError("can't read \(url.path): \(String(cString: strerror(errno)))")
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ToolConfigRefusal.file("it isn't a regular file") }
        guard info.st_size <= maximumFileBytes else { throw ToolConfigRefusal.file("it is larger than 4 MiB") }
        return try Data(contentsOf: url)
    }

    private static func mode(of url: URL) throws -> mode_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw ToolConfigWriterError("can't read \(url.path): \(String(cString: strerror(errno)))")
        }
        return info.st_mode & 0o7777
    }

    // MARK: - Backups

    private var backupFolder: URL {
        stateDirectory.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(tool.rawValue, isDirectory: true)
    }

    /// Copies `data` byte for byte to a new 0600 backup; a second backup in the same second gets `-2`, then `-3`.
    private func makeBackup(of data: Data, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now())
        for attempt in 1...100 {
            let backup = backupFolder.appendingPathComponent("\(name).\(stamp)" + (attempt == 1 ? "" : "-\(attempt)"))
            let descriptor = open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor < 0, errno == EEXIST { continue }
            guard descriptor >= 0 else {
                throw ToolConfigWriterError("can't back up \(name): \(String(cString: strerror(errno)))")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                unlink(backup.path)
                throw ToolConfigWriterError("can't back up \(name): \(error.localizedDescription)")
            }
            return backup
        }
        throw ToolConfigWriterError("can't back up \(name): too many backups this second")
    }

    private func pruneBackups(named name: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupFolder.path)) ?? []
        let newestFirst = names.filter { $0.hasPrefix(name + ".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for old in newestFirst.dropFirst(keptBackups) {
            try? FileManager.default.removeItem(at: backupFolder.appendingPathComponent(old))
        }
    }

    // MARK: - Lock

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = stateDirectory.appendingPathComponent(".lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ToolConfigWriterError("can't open \(lock.path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(Self.lockTimeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                throw ToolConfigWriterError("another \(BuildEnvironment.current.cliName) run is editing tool configs; run this again")
            }
            usleep(50_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// An I/O failure while editing; the tool's file is as it was.
struct ToolConfigWriterError: Error, CustomStringConvertible, Equatable {
    let description: String

    init(_ description: String) { self.description = description }
}
