/// Binary self-hash computation and file hashing utilities.

import CryptoKit
import Darwin
import Foundation
import os

private let hashLogger = Logger(subsystem: "dev.darkbloom.provider", category: "security")


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
