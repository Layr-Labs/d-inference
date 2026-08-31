import Foundation
import InferenceWorkerProtocol

public enum ModelArtifactBrokerError: Error, Equatable, Sendable {
    case noApprovedRoots
    case invalidModelIdentifier
    case outsideApprovedRoot
    case symbolicLink
    case notDirectory
    case manifestHashUnavailable
    case manifestHashMismatch
    case artifactTooLarge
    case bookmarkCreationFailed
}

/// Resolves an already-approved model snapshot into an immutable, read-only,
/// hash-bound capability for the sandboxed inference worker. The broker never
/// grants a parent directory and rejects every symlink rather than attempting to
/// reason about a mutable link target after the grant has been issued.
public struct ModelArtifactBroker: Sendable {
    public static let maximumArtifactBytes: UInt64 = 512 * 1024 * 1024 * 1024
    public let approvedRoots: [URL]

    public init(approvedRoots: [URL] = [ModelScanner.defaultCacheDirectory()].compactMap { $0 }) throws {
        let roots = approvedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !roots.isEmpty else { throw ModelArtifactBrokerError.noApprovedRoots }
        self.approvedRoots = roots
    }

    public func descriptor(modelIdentifier: String, snapshotURL: URL, expectedManifestSHA256: String) throws -> WorkerModelArtifactDescriptor {
        guard !modelIdentifier.isEmpty, modelIdentifier.utf8.count <= InferenceWorkerContract.maximumIdentifierBytes,
              !modelIdentifier.contains(".."), !modelIdentifier.contains("\0"),
              expectedManifestSHA256.count == 64 else {
            throw ModelArtifactBrokerError.invalidModelIdentifier
        }

        let standardized = snapshotURL.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard standardized.path == resolved.path else { throw ModelArtifactBrokerError.symbolicLink }
        guard approvedRoots.contains(where: { Self.isDescendant(resolved, of: $0) }) else {
            throw ModelArtifactBrokerError.outsideApprovedRoot
        }
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true else { throw ModelArtifactBrokerError.notDirectory }
        guard values.isSymbolicLink != true else { throw ModelArtifactBrokerError.symbolicLink }
        let repositoryRoot = resolved.deletingLastPathComponent().lastPathComponent == "snapshots"
            ? resolved.deletingLastPathComponent().deletingLastPathComponent()
            : resolved
        guard approvedRoots.contains(where: {
            Self.isDescendant(repositoryRoot, of: $0)
        }) else {
            throw ModelArtifactBrokerError.outsideApprovedRoot
        }

        let byteCount = try inspectTree(root: resolved, allowedTargetRoot: repositoryRoot)
        guard byteCount > 0, byteCount <= Self.maximumArtifactBytes else {
            throw ModelArtifactBrokerError.artifactTooLarge
        }
        guard let actual = WeightHasher.computeHash(snapshotDir: resolved, modelID: modelIdentifier) else {
            throw ModelArtifactBrokerError.manifestHashUnavailable
        }
        guard actual == expectedManifestSHA256 else {
            throw ModelArtifactBrokerError.manifestHashMismatch
        }

        let bookmark: Data
        do {
            bookmark = try repositoryRoot.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: [.fileResourceIdentifierKey, .isDirectoryKey],
                relativeTo: nil)
        } catch {
            throw ModelArtifactBrokerError.bookmarkCreationFailed
        }
        guard let descriptor = WorkerModelArtifactDescriptor(
            modelIdentifier: modelIdentifier,
            canonicalPath: resolved.path,
            manifestSHA256: actual,
            bookmark: bookmark,
            byteCount: byteCount) else {
            throw ModelArtifactBrokerError.bookmarkCreationFailed
        }
        return descriptor
    }

    private func inspectTree(root: URL, allowedTargetRoot: URL) throws -> UInt64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw ModelArtifactBrokerError.notDirectory
        }
        var total: UInt64 = 0
        for case let item as URL in enumerator {
            let target = item.resolvingSymlinksInPath()
            guard item.standardizedFileURL.path.hasPrefix(
                    root.standardizedFileURL.path + "/"),
                  Self.isDescendant(target, of: allowedTargetRoot) else {
                throw ModelArtifactBrokerError.symbolicLink
            }
            let targetValues = try target.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey])
            if targetValues.isRegularFile == true {
                let size = UInt64(max(0, targetValues.fileSize ?? 0))
                let (next, overflow) = total.addingReportingOverflow(size)
                guard !overflow, next <= Self.maximumArtifactBytes else {
                    throw ModelArtifactBrokerError.artifactTooLarge
                }
                total = next
            }
        }
        return total
    }

    public static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
