import Foundation
import Darwin
import ProviderCoreFoundation

/// What the saved setup's installed files look like on this Mac: the worker
/// binary, what that binary carries, and the model directory's inventory.
/// Read-only, and none of it loads a model or reads a weight payload.
public struct ClusterConsoleInstalled: Encodable, Sendable, Equatable {
    public struct Finding: Encodable, Sendable, Equatable {
        public let verified: Bool
        /// The error text when not verified.
        public let detail: String?
        static let verified = Finding(verified: true, detail: nil)
        static func failed(_ error: Error) -> Finding { .init(verified: false, detail: ClusterConsoleText.bounded(error)) }
    }

    /// Manifest entries found in the model directory. Presence and size only:
    /// the native loader, not this listing, verifies weight contents.
    public struct ArtifactFiles: Encodable, Sendable, Equatable {
        public let expected: Int
        public let present: Int
        public let expectedBytes: Int64
        /// Manifest paths that are missing or whose size differs, first few only.
        public let missingOrDifferent: [String]
    }

    /// The worker binary hashes to the saved runtime pin.
    public let workerBinary: Finding
    /// Nil when the binary could not be verified, so it was not inspected.
    public let hasProgressGuard: Bool?
    public let acceptsStartupDeadline: Bool?
    /// The manifest hashes to its pin and describes the saved model.
    public let manifest: Finding
    /// Nil when the manifest could not be verified.
    public let artifactFiles: ArtifactFiles?

    private static let listedProblems = 6

    static func inspect(saved: ClusterConfigurationStore.Saved, paths: ClusterUserPaths, deadline: UInt64) -> ClusterConsoleInstalled {
        let plan: DistributedInstalledPlan
        do { plan = try DistributedInstalledPlan(saved: saved, paths: paths) } catch {
            return .init(workerBinary: .failed(error), hasProgressGuard: nil, acceptsStartupDeadline: nil,
                manifest: .failed(error), artifactFiles: nil)
        }
        var worker = Finding.verified, features: DistributedInstalledWorkerFeatures?
        do {
            let executable = try DistributedInstalledFiles.verify(URL(fileURLWithPath: plan.localPeer.workerExecutable),
                expectedSHA256: plan.capability.runtimeBinarySHA256, maximumBytes: 256 * 1024 * 1024,
                executable: true, deadline: deadline)
            features = try DistributedInstalledWorkerFeatures.inspect(executable, deadline: deadline)
        } catch { worker = .failed(error) }

        var manifest = Finding.verified, files: ArtifactFiles?
        do {
            let value = try DistributedInstalledManifest.validate(
                ClusterConfigurationFiles.read(plan.manifestURL, maximum: 65_536),
                configuration: plan.configuration, capability: plan.capability)
            files = artifactFiles(value, directory: URL(fileURLWithPath: plan.localPeer.modelDirectory))
        } catch { manifest = .failed(error) }
        return .init(workerBinary: worker, hasProgressGuard: features?.hasProgressGuard,
            acceptsStartupDeadline: features?.acceptsStartupDeadline, manifest: manifest, artifactFiles: files)
    }

    /// One `lstat` per manifest entry: a regular file of the manifest's size.
    static func artifactFiles(_ manifest: ModelManifest, directory: URL) -> ArtifactFiles {
        var present = 0, problems = [String]()
        for file in manifest.files {
            var information = stat()
            let found = lstat(directory.appendingPathComponent(file.path).path, &information) == 0
                && information.st_mode & S_IFMT == S_IFREG && Int64(information.st_size) == file.sizeBytes
            if found { present += 1 } else if problems.count < listedProblems { problems.append(file.path) }
        }
        return .init(expected: manifest.files.count, present: present, expectedBytes: manifest.totalSizeBytes,
            missingOrDifferent: problems)
    }
}
