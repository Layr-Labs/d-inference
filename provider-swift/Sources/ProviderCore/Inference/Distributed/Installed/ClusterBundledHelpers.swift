import Foundation

/// Where this installation's cluster helpers are when no setup names a worker
/// yet: the worker a member launches for its rank and the placement tool the
/// setup runs beside it.
///
/// - The release ships them inside the app, signed under their own Developer
///   ID identifiers: `Darkbloom.app/Contents/Helpers/darkbloom-cluster-worker`
///   (with `darkbloom-cluster-plan`, `mlx.metallib` and `pagedattention.metal`
///   beside it; `scripts/build-cluster-helpers.sh` builds them and the release
///   check refuses an app without them).
/// - A development build keeps them in `worker/` beside `darkbloom`.
///
/// The installer exposes `darkbloom` through `~/.darkbloom/bin` symlinks, so
/// the executable path is resolved first: a symlinked launch still finds the
/// helpers inside the app it runs from.
public enum ClusterBundledHelpers {
    public static let workerName = "darkbloom-cluster-worker"
    public static let developmentDirectory = "worker"

    /// The default worker for the `darkbloom` executable at `executable`.
    public static func defaultWorker(darkbloomExecutable executable: URL) -> URL {
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        let directory = resolved.deletingLastPathComponent()
        if let app = enclosingApp(ofMainExecutableDirectory: directory) {
            return app.appendingPathComponent("Contents/Helpers", isDirectory: true).appendingPathComponent(workerName)
        }
        return directory.appendingPathComponent(developmentDirectory, isDirectory: true).appendingPathComponent(workerName)
    }

    /// What a person reads when the default worker is missing.
    public static func missingWorkerReason(darkbloomExecutable executable: URL) -> String {
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        if enclosingApp(ofMainExecutableDirectory: resolved.deletingLastPathComponent()) != nil {
            return "this Mac's cluster worker is not in Darkbloom.app (expected Contents/Helpers/\(workerName)); reinstall Darkbloom"
        }
        return "this Mac's cluster worker is not installed beside darkbloom (expected \(developmentDirectory)/\(workerName)); reinstall Darkbloom"
    }

    /// `/X/Darkbloom.app/Contents/MacOS` -> `/X/Darkbloom.app`.
    static func enclosingApp(ofMainExecutableDirectory directory: URL) -> URL? {
        let contents = directory.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard directory.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }
}
