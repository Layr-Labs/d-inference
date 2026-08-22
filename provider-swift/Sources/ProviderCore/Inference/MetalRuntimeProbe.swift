// Copyright © 2026 Eigen Labs.

import Foundation

#if os(macOS)
    import Metal
#endif

/// Direct Metal probe used to explain an all-zero MLX diagnostics snapshot.
///
/// MLX builds its `Device` lazily and throws out of the constructor when
/// `MTLCopyAllDevices()`/`MTLCreateSystemDefaultDevice()` yield nothing or when
/// the colocated metallib cannot be loaded. Every C-facade diagnostics entry
/// point swallows that exception, so the failure surfaces to Swift as a
/// perfectly plausible "the route was never requested". This probe repeats the
/// same two steps with the Metal framework directly, where the real `NSError`
/// is catchable.
public enum MetalRuntimeProbe {
    /// Library-load seam. Returns `nil` on success or the failure text
    /// otherwise. Production supplies Metal; tests supply a stub.
    public typealias LibraryLoader = (URL) -> String?

    public static func diagnose(
        executableDirectory: URL? = defaultExecutableDirectory(),
        hostOS: String = PackagedMetallib.versionString(
            ProcessInfo.processInfo.operatingSystemVersion),
        fileManager: FileManager = .default
    ) -> MetalRuntimeDiagnosis {
        classify(
            executableDirectory: executableDirectory,
            hostOS: hostOS,
            fileManager: fileManager,
            loader: metalLibraryLoader())
    }

    /// Pure classifier over the packaged layout. A `nil` loader means no Metal
    /// device could be obtained at all.
    static func classify(
        executableDirectory: URL?,
        hostOS: String,
        fileManager: FileManager = .default,
        loader: LibraryLoader?
    ) -> MetalRuntimeDiagnosis {
        guard let loader else { return .noMetalDevice }
        guard let executableDirectory else { return .unknownExecutableDirectory }

        var attempts: [PackagedMetallibAttempt] = []
        for url in PackagedMetallib.candidateURLs(
            executableDirectory: executableDirectory)
        {
            guard fileManager.isReadableFile(atPath: url.path) else {
                // A present-but-unreadable library is a permissions bug, not a
                // missing file, and the two need different remedies.
                let reason = fileManager.fileExists(atPath: url.path)
                    ? "present but unreadable" : "not present"
                attempts.append(
                    PackagedMetallibAttempt(path: url.path, failure: reason))
                continue
            }
            guard let failure = loader(url) else { return .healthy }
            attempts.append(
                PackagedMetallibAttempt(path: url.path, failure: failure))
        }
        return .noLoadableMetallib(hostOS: hostOS, attempts: attempts)
    }

    /// Directory MLX resolves its colocated metallib against: the real
    /// executable, with `~/.darkbloom/bin` symlinks collapsed.
    public static func defaultExecutableDirectory() -> URL? {
        Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    /// `nil` when no Metal device can be obtained at all.
    private static func metalLibraryLoader() -> LibraryLoader? {
        // `os(macOS)` rather than the repo's usual `canImport(Metal)`:
        // MTLCopyAllDevices is a macOS-only symbol.
        #if os(macOS)
            // Same acquisition order as MLX's `load_device()`, so this probe
            // cannot report "no device" for a session MLX would have served.
            guard
                let device = MTLCopyAllDevices().first
                    ?? MTLCreateSystemDefaultDevice()
            else {
                return nil
            }
            return { url in
                do {
                    _ = try device.makeLibrary(URL: url)
                    return nil
                } catch {
                    return (error as NSError).localizedDescription
                }
            }
        #else
            return nil
        #endif
    }
}
