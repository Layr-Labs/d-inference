// Copyright © 2026 Eigen Labs.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SSDActiveIOOperation: Sendable {
    case read
    case write
    case touch
    case delete
}

/// Descriptor-relative active I/O for the SSD cache. On Darwin every absolute
/// directory component is opened with `O_NOFOLLOW`, then file operations stay
/// relative to the verified parent descriptor. A concurrent pathname swap can
/// detach that directory, but can never redirect I/O through a replacement
/// symlink.
enum SSDNoFollowIO {
    #if canImport(Darwin)
    static func openRegularFileForReading(
        at url: URL,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) throws -> FileHandle {
        let (parentFD, name) = try openVerifiedParent(of: url)
        defer { Darwin.close(parentFD) }
        beforeOperation?(.read)
        let fd = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { throw posixError("openat read", url: url) }
        guard isRegularFile(fd) else {
            Darwin.close(fd)
            throw SSDBlockStoreError.ioFailure("read target is not a regular file")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func writeAtomically(
        to url: URL,
        strictFsync: Bool,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil,
        writer: (FileHandle) throws -> Void
    ) throws -> Int {
        let (parentFD, name) = try openVerifiedBlockParentForWrite(of: url)
        defer { Darwin.close(parentFD) }
        beforeOperation?(.write)

        var existing = stat()
        let existingResult = name.withCString {
            fstatat(parentFD, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        if existingResult == 0, (existing.st_mode & S_IFMT) != S_IFREG {
            throw SSDBlockStoreError.ioFailure("write target is not a regular file")
        }
        if existingResult != 0, errno != ENOENT {
            throw posixError("fstatat write target", url: url)
        }

        let tempName = "\(name).\(SSDBlockStore.tempMarker).\(UUID().uuidString)"
        let fd = tempName.withCString {
            openat(
                parentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw posixError("openat temp", url: url) }
        var renamed = false
        defer {
            if !renamed {
                tempName.withCString { _ = unlinkat(parentFD, $0, 0) }
            }
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try writer(handle)
            if strictFsync { try handle.synchronize() }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw posixError("fstat temp", url: url)
            }
            let fileBytes = info.st_size > off_t(Int.max) ? Int.max : Int(info.st_size)
            try handle.close()
            let renameResult = tempName.withCString { tempPtr in
                name.withCString { namePtr in
                    renameat(parentFD, tempPtr, parentFD, namePtr)
                }
            }
            guard renameResult == 0 else { throw posixError("renameat", url: url) }
            renamed = true
            return max(0, fileBytes)
        } catch {
            try? handle.close()
            throw error
        }
    }

    @discardableResult
    static func unlinkRegularFile(
        at url: URL,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) -> Bool {
        guard let (parentFD, name) = try? openVerifiedParent(of: url) else { return false }
        defer { Darwin.close(parentFD) }
        beforeOperation?(.delete)
        var info = stat()
        let statResult = name.withCString {
            fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return name.withCString { unlinkat(parentFD, $0, 0) == 0 }
    }

    static func touchRegularFile(
        at url: URL,
        modificationDate: Date,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) {
        guard let (parentFD, name) = try? openVerifiedParent(of: url) else { return }
        defer { Darwin.close(parentFD) }
        beforeOperation?(.touch)
        let fd = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard isRegularFile(fd) else { return }
        let interval = modificationDate.timeIntervalSince1970
        let seconds = time_t(interval.rounded(.down))
        let nanoseconds = Int((interval - Double(seconds)) * 1_000_000_000)
        var times = [
            timespec(tv_sec: seconds, tv_nsec: nanoseconds),
            timespec(tv_sec: seconds, tv_nsec: nanoseconds),
        ]
        _ = futimens(fd, &times)
    }

    private static func openVerifiedParent(of url: URL) throws -> (Int32, String) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SSDBlockStoreError.ioFailure("invalid cache filename")
        }
        return (try openDirectoryChain(parent), name)
    }

    private static func openVerifiedBlockParentForWrite(
        of url: URL
    ) throws -> (Int32, String) {
        let fanoutURL = url.deletingLastPathComponent().standardizedFileURL
        let modelURL = fanoutURL.deletingLastPathComponent()
        let fanout = fanoutURL.lastPathComponent
        let name = url.lastPathComponent
        guard SSDBlockStore.isLowerHex(fanout, count: 2),
            !name.isEmpty, !name.contains("/")
        else { throw SSDBlockStoreError.ioFailure("invalid block path") }
        let modelFD = try openDirectoryChain(modelURL)
        defer { Darwin.close(modelFD) }
        let mkdirResult = fanout.withCString {
            mkdirat(modelFD, $0, S_IRWXU)
        }
        guard mkdirResult == 0 || errno == EEXIST else {
            throw posixError("mkdirat fanout", url: fanoutURL)
        }
        let fanoutFD = fanout.withCString {
            openat(modelFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fanoutFD >= 0 else {
            throw posixError("openat fanout", url: fanoutURL)
        }
        return (fanoutFD, name)
    }

    private static func openDirectoryChain(_ directory: URL) throws -> Int32 {
        let rawPath = directory.path
        // macOS exposes these immutable system aliases as symlinks. Normalize
        // only those known aliases textually; never resolve a cache-controlled
        // component before the O_NOFOLLOW descriptor walk.
        let canonicalPath: String
        if rawPath == "/var" || rawPath.hasPrefix("/var/") {
            canonicalPath = "/private" + rawPath
        } else if rawPath == "/tmp" || rawPath.hasPrefix("/tmp/") {
            canonicalPath = "/private" + rawPath
        } else {
            canonicalPath = rawPath
        }
        guard canonicalPath.hasPrefix("/") else {
            throw SSDBlockStoreError.ioFailure("cache path is not absolute")
        }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw posixError("open root", url: directory) }
        do {
            for component in URL(fileURLWithPath: canonicalPath).pathComponents.dropFirst() {
                guard !component.isEmpty, component != ".", component != "..", component != "/"
                else { throw SSDBlockStoreError.ioFailure("unsafe cache path component") }
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else {
                    throw SSDBlockStoreError.ioFailure(
                        "openat directory \(component) under \(canonicalPath): "
                            + String(cString: strerror(errno)))
                }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func isRegularFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func posixError(_ operation: String, url: URL) -> SSDBlockStoreError {
        SSDBlockStoreError.ioFailure(
            "\(operation) \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
    #else
    static func openRegularFileForReading(
        at url: URL,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) throws -> FileHandle {
        beforeOperation?(.read)
        guard SSDBlockStore.isSafeBlockURL(url) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
        return try FileHandle(forReadingFrom: url)
    }

    static func writeAtomically(
        to url: URL,
        strictFsync: Bool,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil,
        writer: (FileHandle) throws -> Void
    ) throws -> Int {
        beforeOperation?(.write)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard SSDBlockStore.isSafeBlockURL(url) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
        let temp = SSDBlockStore.temporaryFileURL(for: url)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw SSDBlockStoreError.ioFailure("create tmp failed")
        }
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try writer(handle)
            if strictFsync { try handle.synchronize() }
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    static func unlinkRegularFile(
        at url: URL,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) -> Bool {
        beforeOperation?(.delete)
        guard SSDBlockStore.isSafeDescendant(
            url, under: url.deletingLastPathComponent().deletingLastPathComponent())
        else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    static func touchRegularFile(
        at url: URL,
        modificationDate: Date,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) {
        beforeOperation?(.touch)
        try? FileManager.default.setAttributes(
            [.modificationDate: modificationDate], ofItemAtPath: url.path)
    }
    #endif
}
