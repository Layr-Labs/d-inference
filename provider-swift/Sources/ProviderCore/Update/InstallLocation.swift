// Copyright © 2026 Eigen Labs.
//
// Where is this process actually running from?
//
// The updater stages a new bundle into a side directory, verifies it, and only
// then renames it into the live layout. Nothing is supposed to EXECUTE from a
// side directory — but nothing checked, and a provider that ends up doing so
// is stranded in a way no existing surface reveals:
//
//   * `SelfUpdater.resolvedInstallRoot()` derives the install root from the
//     running executable's path, so a process running out of
//     `~/.darkbloom/.update-staging-<uuid>/Darkbloom.app/Contents/MacOS/` will
//     treat the STAGING directory as its install root and stage, commit, and
//     roll back inside it forever. The real install is never repaired.
//
//   * `BinaryHasher.locateMetallib()` resolves `mlx.metallib` next to the
//     running executable, so the coordinator receives the staging tree's
//     hashes, they match no registered release, and the machine is derouted
//     with `runtime_verified=false` while still connected and heartbeating.
//
// The result is a node that reports online, hardware-trusted, challenge-
// passing and locally healthy while serving nothing, and whose only apparent
// escape is a full reinstall. This type is the check that names it. It is pure
// path arithmetic over the executable path, so `doctor` can run it without the
// daemon and tests can run it without a filesystem.

import Foundation

public enum InstallLocation {

    /// Directory-name prefixes the updater uses for trees that are, by
    /// construction, transient: they exist only between the steps of an
    /// install and are renamed or deleted when it finishes.
    ///
    /// Where a constant already exists it is referenced rather than copied, so
    /// renaming one cannot leave a hole here. The remaining literals are the
    /// names built inline at their single construction site; each cites it.
    public static let transientDirPrefixes = [
        SelfUpdater.stagingDirPrefix,  // SelfUpdater.stageBundle
        UpdateRecoveryStore.staleAppAsidePrefix,  // stale-app retirement, via atomicRemove
        ".update-backup-",  // SelfUpdater backup swap
        ".rollback-staging-",  // UpdateRecoveryStore.rollbackToPredecessor
        ".recovery-restore-",  // UpdateRecoveryStore.restore
        ".predecessor-next-",  // UpdateInstallLayout.snapshotLiveAsPredecessor
    ]

    public enum Verdict: Sendable, Equatable {
        /// Running from a normal install layout.
        case live
        /// Running from inside a transient update directory. `directory` is
        /// the offending path component (never a full path — it embeds only a
        /// prefix and a UUID).
        case transient(directory: String)

        public var isTransient: Bool {
            if case .transient = self { return true }
            return false
        }
    }

    /// Classify an executable path. Symlinks are resolved first: invoked as
    /// plain `darkbloom` the path is the `/usr/local/bin` PATH symlink, which
    /// says nothing about where the bytes live — the same resolution
    /// `SelfUpdater.installRoot(forExecutablePath:)` performs before deriving
    /// the install root, so the two agree about what "here" means.
    public static func classify(executablePath: String) -> Verdict {
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        for component in resolved.pathComponents {
            for prefix in transientDirPrefixes where component.hasPrefix(prefix) {
                return .transient(directory: component)
            }
        }
        return .live
    }

    /// Classify the running process.
    public static func current(
        executablePath: String? = Bundle.main.executablePath
    ) -> Verdict {
        guard let executablePath else { return .live }
        return classify(executablePath: executablePath)
    }

    /// Operator-facing explanation for a transient verdict, or nil when the
    /// install location is fine. Content-free: the only interpolation is the
    /// directory name, which is a fixed prefix plus a UUID.
    public static func remediation(for verdict: Verdict) -> String? {
        guard case .transient(let directory) = verdict else { return nil }
        return "running from the transient update directory \(directory) instead of the "
            + "live install. An update staged a bundle here and never finished swapping it "
            + "in, so this process reports the staged tree's runtime hashes — which match "
            + "no registered release — and the coordinator will not route to it. Reinstall "
            + "with the official installer to restore the live layout."
    }
}
