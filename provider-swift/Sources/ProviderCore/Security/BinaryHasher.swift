/// Binary self-hash computation and file hashing utilities.

import CryptoKit
import Darwin
import Foundation
import ProviderMetallibControl
import os

private let hashLogger = Logger(subsystem: "dev.darkbloom.provider", category: "security")

enum RuntimeMetallibBindingError: Error {
    case sourceUnavailable
    case snapshotCreateFailed
    case snapshotUnlinkFailed
}

final class RuntimeMetallibSnapshot: @unchecked Sendable {
    let fileDescriptor: Int32
    let digest: String
    let loaderPath: String

    init(fileDescriptor: Int32, digest: String) {
        self.fileDescriptor = fileDescriptor
        self.digest = digest
        self.loaderPath = "/dev/fd/\(fileDescriptor)"
    }

    deinit {
        Darwin.close(fileDescriptor)
    }
}

private let runtimeMetallibBindingLock = NSLock()
nonisolated(unsafe) private var boundRuntimeMetallib: RuntimeMetallibSnapshot?

// MARK: - Binary Self-Hash

/// Compute the SHA-256 hash of the currently running binary.
///
/// This hash is included in the attestation blob so the coordinator can
/// verify the provider is running the expected (blessed) version. A modified
/// binary produces a different hash and is rejected.
///
/// Reads in 64 KB chunks to avoid loading the entire binary into memory.
public func selfBinaryHash() -> String? {
    guard let path = executablePath() else {
        hashLogger.error("Binary self-hash: cannot determine executable path")
        return nil
    }
    guard let hash = hashFile(atPath: path) else {
        hashLogger.error("Binary self-hash: failed to hash \(path, privacy: .public)")
        return nil
    }
    let prefix = hash.prefix(16)
    hashLogger.info("Binary self-hash (\(path, privacy: .public)): \(prefix, privacy: .public)...")
    return hash
}

/// Compute the SHA-256 hash of a file using streaming reads.
///
/// Reads in 64 KB chunks to avoid loading entire files into memory.
/// Used for binary integrity verification and model weight fingerprinting.
public func hashFile(atPath path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        return nil
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    let chunkSize = 65_536

    while true {
        let chunk = handle.readData(ofLength: chunkSize)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }

    let digest = hasher.finalize()
    return digest.hexString
}

/// Compute SHA-256 of a byte buffer, returning the hex digest.
public func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.hexString
}

/// Compute a deterministic SHA-256 fingerprint over multiple files.
///
/// Each file is hashed independently, then the per-file hashes are combined
/// in sorted filename order into a final hash. This produces a consistent
/// result regardless of filesystem ordering.
public func hashFilesSorted(_ paths: [String]) -> String? {
    let sorted = paths.sorted()
    var finalHasher = SHA256()

    for path in sorted {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        var fileHasher = SHA256()
        let chunkSize = 65_536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            fileHasher.update(data: chunk)
        }

        let fileDigest = fileHasher.finalize()
        finalHasher.update(data: Data(fileDigest))
    }

    let digest = finalHasher.finalize()
    return digest.hexString
}

// MARK: - Metallib hashing

/// Locate the `mlx.metallib` the C++ MLX loader will actually select.
///
/// MLX checks the binary directory in this order:
///   1. `<executable-dir>/mlx.metallib`
///   2. `<executable-dir>/Resources/mlx.metallib`
///
/// `MLX_METALLIB_PATH` is intentionally ignored: MLX does not read that
/// environment variable. A custom file is load-bearing only after an explicit
/// `mlx::core::metal::set_metallib_path` C-API call; ProviderCore makes no such
/// call. Hashing an env-only path would attest one file while MLX loads another.
public func locateRuntimeMetallib() -> URL? {
    guard let path = executablePath() else { return nil }
    return locateRuntimeMetallib(
        executableURL: URL(fileURLWithPath: path),
        fileExists: { FileManager.default.fileExists(atPath: $0.path) }
    )
}

/// Dependency-injected form used to prove loader precedence without mutating the
/// running test bundle.
func locateRuntimeMetallib(
    executableURL: URL,
    fileExists: (URL) -> Bool
) -> URL? {
    let directory = executableURL.deletingLastPathComponent()
    let candidates = [
        directory.appendingPathComponent("mlx.metallib"),
        directory.appendingPathComponent("Resources/mlx.metallib"),
    ]
    return candidates.first(where: fileExists)
}

/// Copy the selected metallib into an unlinked, open file and hash the bytes
/// during that copy. `/dev/fd/N` lets MLX load the exact retained inode; later
/// replacements of the public colocated pathname cannot change loaded bytes.
func makeRuntimeMetallibSnapshot(
    sourceURL: URL,
    onAnonymousReady: ((String) -> Void)? = nil
) throws -> RuntimeMetallibSnapshot {
    guard let source = FileHandle(forReadingAtPath: sourceURL.path) else {
        throw RuntimeMetallibBindingError.sourceUnavailable
    }
    defer { try? source.close() }

    var template = Array(
        (NSTemporaryDirectory() + "darkbloom-mlx-metallib.XXXXXX").utf8CString
    )
    let descriptor = template.withUnsafeMutableBufferPointer {
        mkstemp($0.baseAddress)
    }
    guard descriptor >= 0 else {
        throw RuntimeMetallibBindingError.snapshotCreateFailed
    }
    let temporaryPath = String(cString: template)
    guard unlink(temporaryPath) == 0 else {
        Darwin.close(descriptor)
        throw RuntimeMetallibBindingError.snapshotUnlinkFailed
    }
    // From this point onward no filesystem name exists for the writable fd.
    // A same-UID peer cannot open/retain a second writer during copy+hash.
    onAnonymousReady?(temporaryPath)
    var retainDescriptor = false
    defer {
        if !retainDescriptor {
            Darwin.close(descriptor)
        }
    }

    let destination = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
    )
    var hasher = SHA256()
    while true {
        let bytes = try source.read(upToCount: 1024 * 1024) ?? Data()
        if bytes.isEmpty { break }
        try destination.write(contentsOf: bytes)
        hasher.update(data: bytes)
    }
    try destination.synchronize()
    _ = fchmod(descriptor, S_IRUSR)
    try destination.seek(toOffset: 0)
    retainDescriptor = true
    return RuntimeMetallibSnapshot(
        fileDescriptor: descriptor,
        digest: hasher.finalize().hexString
    )
}

/// Pin MLX to an anonymous snapshot before the first GPU diagnostic/operation.
/// The returned digest describes the retained inode MLX loads, not a mutable
/// public pathname.
public func bindRuntimeMetallibForMLX() -> String? {
    runtimeMetallibBindingLock.lock()
    defer { runtimeMetallibBindingLock.unlock() }
    if let boundRuntimeMetallib {
        return boundRuntimeMetallib.digest
    }
    guard let source = locateRuntimeMetallib() else { return nil }
    do {
        let snapshot = try makeRuntimeMetallibSnapshot(sourceURL: source)
        snapshot.loaderPath.withCString {
            darkbloom_mlx_set_metallib_path($0)
        }
        boundRuntimeMetallib = snapshot
        return snapshot.digest
    } catch {
        hashLogger.error("Failed to bind runtime metallib: \(error)")
        return nil
    }
}

/// SHA-256 hash of the metallib the live MLX loader selects. Returns nil when
/// neither loader-visible path exists; capability detection then fails closed.
public func metallibHash() -> String? {
    runtimeMetallibBindingLock.lock()
    defer { runtimeMetallibBindingLock.unlock() }
    return boundRuntimeMetallib?.digest
}

func runtimeMetallibHash(
    executableURL: URL,
    fileExists: (URL) -> Bool
) -> String? {
    guard let url = locateRuntimeMetallib(
        executableURL: executableURL,
        fileExists: fileExists
    ) else {
        return nil
    }
    return hashFile(atPath: url.path)
}

// MARK: - Helpers

/// Get the path to the currently running executable.
func executablePath() -> String? {
    // ProcessInfo gives us the full resolved path
    let args = ProcessInfo.processInfo.arguments
    guard let first = args.first else { return nil }

    // Resolve via /proc/self or _NSGetExecutablePath for accuracy
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var size = UInt32(MAXPATHLEN)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        return first
    }

    // Resolve symlinks
    guard let resolved = realpath(buffer, nil) else {
        return String(cString: buffer)
    }
    defer { free(resolved) }
    return String(cString: resolved)
}
