// Copyright © 2026 Eigen Labs.

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Artifact-verification counterpart to the installer's
/// `verify_baseline_metallib_capability`.
///
/// The primary `mlx.metallib` is built for macOS 26.2 so it can carry the M5
/// `_nax` kernels, which no older Metal runtime will load. Releases therefore
/// also ship a NAX-free baseline at MLX's second colocated probe path. Marker
/// and file must appear together; pre-baseline releases have neither, and must
/// keep self-updating.
enum BaselineMetallibCapabilityVerifier {
    static func verify(
        app: URL,
        fileManager: FileManager = .default
    ) throws {
        let baseline = app.appendingPathComponent(
            PackagedMetallib.baselineBundleRelativePath)
        let marker = app.appendingPathComponent(
            PackagedMetallib.baselineCapabilityRelativePath)
        let baselinePresent = fileManager.fileExists(atPath: baseline.path)
        let markerPresent = fileManager.fileExists(atPath: marker.path)

        guard baselinePresent || markerPresent else {
            return // pre-baseline release compatibility
        }
        guard baselinePresent, markerPresent else {
            throw UpdateError.replaceFailed(
                baselinePresent
                    ? "baseline Metal kernel library is missing its signed capability marker"
                    : "artifact advertises a baseline Metal kernel library it does not ship")
        }
        try requireNonEmptyRegularFile(
            baseline, label: "baseline Metal kernel library")
        try requireNonEmptyRegularFile(
            marker, label: "baseline metallib capability marker")
        guard
            let markerValue = try? String(contentsOf: marker, encoding: .utf8),
            markerValue.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        else {
            throw UpdateError.replaceFailed(
                "baseline metallib capability marker is invalid")
        }
    }

    private static func requireNonEmptyRegularFile(
        _ url: URL,
        label: String
    ) throws {
        #if canImport(Darwin)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFREG
            else {
                throw UpdateError.replaceFailed(
                    "\(label) must be a regular non-symlink file")
            }
            guard metadata.st_size > 0 else {
                throw UpdateError.replaceFailed("\(label) is empty")
            }
        #else
            guard
                let size = try? FileManager.default.attributesOfItem(
                    atPath: url.path)[.size] as? NSNumber,
                size.intValue > 0
            else {
                throw UpdateError.replaceFailed(
                    "\(label) is missing or empty")
            }
        #endif
    }
}
