import Foundation

/// The paged-runtime capability check a staged `Darkbloom.app` must pass
/// before the updater runs its packaged smoke.
///
/// The signed marker and the paged runtime code in the executable must agree,
/// and both must be present: a release without the marker predates the paged
/// runtime and is no longer installable by self-update.
enum PagedRuntimeCapabilityVerifier {
    /// A string only a paged-capable `darkbloom` binary contains.
    static let binaryCapability = "engine_v2_kv_backend"

    static func verifyMarker(
        app: URL,
        executable: URL,
        fileManager: FileManager = .default
    ) throws {
        let marker = app.appendingPathComponent(
            PackagedRuntimeSmoke.pagedCapabilityRelativePath)
        let markerPresent = fileManager.fileExists(atPath: marker.path)
        let binary = try Data(contentsOf: executable, options: [.mappedIfSafe])
        let pagedCodePresent = binary.range(of: Data(binaryCapability.utf8)) != nil

        guard markerPresent == pagedCodePresent else {
            throw UpdateError.replaceFailed(
                pagedCodePresent
                    ? "paged-capable artifact is missing its signed capability marker"
                    : "artifact advertises paged capability without paged runtime code")
        }
        guard markerPresent else {
            throw UpdateError.replaceFailed(
                "artifact predates the paged runtime; pre-paged releases are no longer installable")
        }
        guard
            let markerValue = try? String(contentsOf: marker, encoding: .utf8),
            markerValue.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        else {
            throw UpdateError.replaceFailed(
                "paged runtime capability marker is invalid")
        }
    }
}
