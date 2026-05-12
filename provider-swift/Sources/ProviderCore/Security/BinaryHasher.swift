/// Binary self-hash computation and file hashing utilities.

import CryptoKit
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
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Compute SHA-256 of a byte buffer, returning the hex digest.
public func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
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
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Metallib hashing

/// Locate the `mlx.metallib` file the running provider would actually load
/// at GPU init time. Order of search:
///
///   1. `${MLX_METALLIB_PATH}` if set (override for tests / vendored builds).
///   2. Sibling of the running executable (`<exe_dir>/mlx.metallib`).
///   3. Common bundled fallbacks (`bin/mlx.metallib` next to the exe dir).
///   4. nil if nothing matches.
///
/// The release pipeline drops the metallib next to `darkbloom`, so case (2)
/// covers both production installs and `swift build` runs that follow the
/// README's pip-install workaround.
public func locateMetallib() -> URL? {
    if let env = ProcessInfo.processInfo.environment["MLX_METALLIB_PATH"], !env.isEmpty {
        let url = URL(fileURLWithPath: env)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
    }

    guard let exePath = executablePath() else { return nil }
    let exeDir = (exePath as NSString).deletingLastPathComponent
    let candidates = [
        URL(fileURLWithPath: exeDir).appendingPathComponent("mlx.metallib"),
        URL(fileURLWithPath: exeDir)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/mlx.metallib"),
        URL(fileURLWithPath: exeDir)
            .deletingLastPathComponent()
            .appendingPathComponent("bin/mlx.metallib"),
    ]
    for candidate in candidates {
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

/// SHA-256 hash of the live `mlx.metallib`. Returns nil if the file isn't
/// found (which means the binary will crash on the first MLX call -- caller
/// should surface that prominently).
public func metallibHash() -> String? {
    guard let url = locateMetallib() else { return nil }
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
