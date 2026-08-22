// Copyright © 2026 Eigen Labs.

import Foundation

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
        // Presence must see a dangling symlink, or two of them read as a
        // pre-baseline release and take the early return. Mirrors the
        // installer's `[ -e ] || [ -L ]`.
        let baselinePresent = itemExists(baseline, fileManager: fileManager)
        let markerPresent = itemExists(marker, fileManager: fileManager)

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
            baseline,
            label: "baseline Metal kernel library",
            fileManager: fileManager)
        try requireNonEmptyRegularFile(
            marker,
            label: "baseline metallib capability marker",
            fileManager: fileManager)
        guard
            let markerValue = try? String(contentsOf: marker, encoding: .utf8),
            markerValue.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        else {
            throw UpdateError.replaceFailed(
                "baseline metallib capability marker is invalid")
        }
    }

    /// `fileExists` follows symlinks; a dangling one must still read as
    /// present so the coupling check fires instead of the early return.
    private static func itemExists(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func requireNonEmptyRegularFile(
        _ url: URL,
        label: String,
        fileManager: FileManager
    ) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        guard let attributes, attributes[.type] as? FileAttributeType == .typeRegular
        else {
            throw UpdateError.replaceFailed(
                "\(label) must be a regular non-symlink file")
        }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw UpdateError.replaceFailed("\(label) is empty")
        }
    }
}
