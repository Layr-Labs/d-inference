import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum UpdateAtomicFilesystem {
    static func writeJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try write(data, to: destination)
    }

    static func write(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw filesystemError("open \(temporary.path)")
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove { try? fm.removeItem(at: temporary) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = DarwinOrGlibcWrite(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw filesystemError("write \(temporary.path)")
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw filesystemError("fsync \(temporary.path)")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw filesystemError("rename \(temporary.path) -> \(destination.path)")
        }
        shouldRemove = false
        syncDirectory(directory)
    }

    /// Atomically exchange two same-volume paths. Both names always reference
    /// a complete tree; there is no interval where the live app path is absent.
    static func exchange(_ first: URL, _ second: URL) throws {
        #if canImport(Darwin)
        let result = renameatx_np(
            AT_FDCWD,
            first.path,
            AT_FDCWD,
            second.path,
            UInt32(RENAME_SWAP)
        )
        guard result == 0 else {
            throw filesystemError("exchange \(first.path) <-> \(second.path)")
        }
        syncDirectory(first.deletingLastPathComponent())
        if first.deletingLastPathComponent() != second.deletingLastPathComponent() {
            syncDirectory(second.deletingLastPathComponent())
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    static func replace(_ source: URL, at destination: URL) throws {
        if itemExists(destination) {
            try exchange(source, destination)
        } else {
            guard rename(source.path, destination.path) == 0 else {
                throw filesystemError("rename \(source.path) -> \(destination.path)")
            }
            syncDirectory(destination.deletingLastPathComponent())
        }
    }

    static func replaceSymlink(at destination: URL, target: String) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).link-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw filesystemError("replace symlink \(destination.path)")
        }
        syncDirectory(directory)
    }

    static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Content-address the complete backup tree. File paths, node kinds,
    /// symlink targets, and regular-file bytes are included in sorted order.
    static func treeHash(root: URL) throws -> String {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var entries: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            entries.append(entry)
        }
        entries.sort { relativePath($0, under: root) < relativePath($1, under: root) }

        var hasher = SHA256()
        for entry in entries {
            let relative = relativePath(entry, under: root)
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: entry.path)
                hashLine("L \(relative) \(target)", into: &hasher)
            } else if values.isDirectory == true {
                hashLine("D \(relative)", into: &hasher)
            } else if values.isRegularFile == true {
                hashLine("F \(relative)", into: &hasher)
                let handle = try FileHandle(forReadingFrom: entry)
                do {
                    while true {
                        let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        hasher.update(data: chunk)
                    }
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                hashLine("", into: &hasher)
            } else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fsyncTree(_ root: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var directories = [root]
        while let entry = enumerator.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isRegularFile == true {
                let descriptor = open(entry.path, O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else { throw filesystemError("open \(entry.path)") }
                let result = fsync(descriptor)
                _ = close(descriptor)
                guard result == 0 else { throw filesystemError("fsync \(entry.path)") }
            } else if values.isDirectory == true {
                directories.append(entry)
            }
        }
        for directory in directories.reversed() {
            syncDirectory(directory)
        }
    }

    static func itemExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func hashLine(_ line: String, into hasher: inout SHA256) {
        hasher.update(data: Data((line + "\n").utf8))
    }

    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = close(descriptor)
    }

    private static func filesystemError(_ operation: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
        )
    }
}

@inline(__always)
private func DarwinOrGlibcWrite(
    _ descriptor: Int32,
    _ pointer: UnsafeRawPointer,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, pointer, count)
    #else
    Glibc.write(descriptor, pointer, count)
    #endif
}
