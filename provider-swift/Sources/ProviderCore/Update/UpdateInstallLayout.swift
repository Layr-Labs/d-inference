import Foundation

/// Concrete `Darkbloom.app` layout operations used by the journaled recovery
/// store.
/// Kept separate from transaction/state orchestration so rename ordering and
/// artifact verification remain independently auditable.
extension UpdateRecoveryStore {
    func snapshotLiveAsPredecessor(
        version: String,
        releaseBundleHash: String?,
        installGeneration: UInt64,
        now: Double
    ) throws -> VerifiedPredecessor {
        try requireLiveApp()
        let nextRoot = recoveryRoot.appendingPathComponent(
            ".predecessor-next-\(UUID().uuidString)",
            isDirectory: true
        )
        try UpdateAtomicFilesystem.createDirectoryDurably(recoveryRoot)
        try UpdateAtomicFilesystem.removeDurably(nextRoot)
        try UpdateAtomicFilesystem.createDirectoryDurably(nextRoot)

        let copied = artifactPaths(root: nextRoot)
        try fm.copyItem(
            at: installRoot.appendingPathComponent("Darkbloom.app"),
            to: copied.bundle)

        try verifySignature(bundle: copied.bundle, binary: copied.binary)
        let release = InstalledReleaseRecord(
            version: version,
            releaseBundleHash: releaseBundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: copied.bundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: copied.binary),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: copied.enclave),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: copied.metallib),
            installGeneration: installGeneration,
            installedAt: stateInstallDateFallback(now)
        )
        let manifest = VerifiedPredecessor(
            release: release,
            layout: .app,
            bundlePath: "predecessor/Darkbloom.app",
            binaryPath: "predecessor/Darkbloom.app/Contents/MacOS/darkbloom",
            enclavePath: "predecessor/Darkbloom.app/Contents/MacOS/darkbloom-enclave",
            metallibPath: "predecessor/Darkbloom.app/Contents/MacOS/mlx.metallib",
            verifiedAt: now
        )
        try UpdateAtomicFilesystem.writeJSON(
            manifest,
            to: nextRoot.appendingPathComponent("manifest.json")
        )
        try UpdateAtomicFilesystem.fsyncTree(nextRoot)

        if fm.fileExists(atPath: predecessorRoot.path) {
            try UpdateAtomicFilesystem.exchange(nextRoot, predecessorRoot)
            try UpdateAtomicFilesystem.removeDurably(nextRoot)
        } else {
            try UpdateAtomicFilesystem.replace(nextRoot, at: predecessorRoot)
        }
        try faultInjector(.predecessorPromoted)
        return manifest
    }

    func recordForStagedBundle(
        _ staged: SelfUpdater.StagedBundle,
        generation: UInt64,
        now: Double
    ) throws -> InstalledReleaseRecord {
        let paths = artifactPaths(root: staged.extractedApp.deletingLastPathComponent())
        return InstalledReleaseRecord(
            version: staged.release.version,
            releaseBundleHash: staged.release.bundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: paths.bundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: paths.binary),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: paths.enclave),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: paths.metallib),
            installGeneration: generation,
            installedAt: now
        )
    }

    func installStagedBundle(_ staged: SelfUpdater.StagedBundle) throws {
        try installApp(from: staged.extractedApp)
        try ensureCanonicalLinks()
    }

    func installFromStaging(_ stagingRoot: URL) throws {
        try installApp(from: artifactPaths(root: stagingRoot).bundle)
    }

    /// Point the canonical `bin/` entries at the installed `Darkbloom.app`.
    func ensureCanonicalLinks() throws {
        guard fm.fileExists(
            atPath: installRoot.appendingPathComponent("Darkbloom.app").path
        ) else {
            throw StoreError.filesystem(
                "canonical links requested but Darkbloom.app is missing")
        }
        let bin = installRoot.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let appBin = "../Darkbloom.app/Contents/MacOS"
        for (name, target) in [
            ("mlx.metallib", "\(appBin)/mlx.metallib"),
            ("darkbloom-enclave", "\(appBin)/darkbloom-enclave"),
            ("darkbloom", "\(appBin)/darkbloom"),
        ] {
            try UpdateAtomicFilesystem.replaceSymlink(
                at: bin.appendingPathComponent(name),
                target: target
            )
        }
    }

    func liveMatches(_ record: InstalledReleaseRecord) throws -> Bool {
        guard try stagingContainsTarget(installRoot, target: record) else {
            return false
        }
        let paths = artifactPaths(root: installRoot)
        try verifySignature(bundle: paths.bundle, binary: paths.binary)
        return true
    }

    func stagingContainsTarget(
        _ stagingRoot: URL,
        target: InstalledReleaseRecord
    ) throws -> Bool {
        let paths = artifactPaths(root: stagingRoot)
        guard fm.fileExists(atPath: paths.binary.path),
              fm.fileExists(atPath: paths.enclave.path),
              fm.fileExists(atPath: paths.metallib.path)
        else {
            return false
        }
        return try UpdateAtomicFilesystem.sha256(file: paths.binary) == target.binaryHash
            && UpdateAtomicFilesystem.sha256(file: paths.enclave) == target.enclaveHash
            && UpdateAtomicFilesystem.sha256(file: paths.metallib) == target.metallibHash
            && UpdateAtomicFilesystem.treeHash(root: paths.bundle)
                == target.installedBundleHash
    }

    func copyPredecessor(
        _ predecessor: VerifiedPredecessor,
        to stagingRoot: URL
    ) throws {
        try UpdateAtomicFilesystem.removeDurably(stagingRoot)
        try UpdateAtomicFilesystem.createDirectoryDurably(stagingRoot)
        let source = try resolvedRecoveryPath(predecessor.bundlePath)
        let destination = artifactPaths(root: stagingRoot).bundle
        try fm.copyItem(at: source, to: destination)
        try UpdateAtomicFilesystem.fsyncTree(stagingRoot)
    }

    func verifyStagedPredecessor(
        _ predecessor: VerifiedPredecessor,
        at stagingRoot: URL
    ) throws {
        let (bundle, binary, enclave, metallib) = artifactPaths(root: stagingRoot)
        guard try UpdateAtomicFilesystem.treeHash(root: bundle)
                == predecessor.release.installedBundleHash,
              try UpdateAtomicFilesystem.sha256(file: binary) == predecessor.release.binaryHash,
              try UpdateAtomicFilesystem.sha256(file: enclave) == predecessor.release.enclaveHash,
              try UpdateAtomicFilesystem.sha256(file: metallib) == predecessor.release.metallibHash
        else {
            throw StoreError.predecessorVerificationFailed(
                "rollback staging copy changed during copy")
        }
        try verifySignature(bundle: bundle, binary: binary)
    }

    func restorePredecessorCopy(
        _ predecessor: VerifiedPredecessor,
        stagingName: String
    ) throws {
        let staging = installRoot.appendingPathComponent(stagingName, isDirectory: true)
        try copyPredecessor(predecessor, to: staging)
        try verifyStagedPredecessor(predecessor, at: staging)
        try installFromStaging(staging)
        try ensureCanonicalLinks()
        try UpdateAtomicFilesystem.removeDurably(staging)
    }

    /// INTENTIONALLY FAIL-CLOSED for ad-hoc or re-signed installs: an install
    /// whose live binary does not satisfy the pinned Darkbloom designated
    /// requirement (Team SLDQ2GJ6TL) is not eligible as rollback material and
    /// its replay/rollback verification refuses. Accepting a structurally
    /// valid but unpinned signature would let any locally re-signed binary
    /// become "verified" recovery state. Fleet impact and the recorded
    /// decision live in the threat model (T-043); the remedy for an affected
    /// host is a signed reinstall via install.sh.
    func verifySignature(bundle: URL, binary: URL) throws {
        guard verifyCodeSignatures else { return }
        #if canImport(Darwin)
        do {
            try DarkbloomCodeSignature.verify(bundle, deep: true)
            try FanHelperCapabilityVerifier.verify(
                app: bundle,
                executable: binary,
                signaturePolicy: .darkbloomProduction
            )
        } catch {
            throw StoreError.predecessorVerificationFailed(
                "\(bundle.lastPathComponent) does not satisfy the pinned Darkbloom "
                    + "designated requirement (Team \(DarkbloomCodeSignature.teamID)). "
                    + "Legacy ad-hoc or re-signed installs are intentionally not "
                    + "rollback-eligible (fail-closed); reinstall via install.sh to "
                    + "restore signed rollback material. codesign: \(error.localizedDescription)")
        }
        #endif
    }

    func resolvedRecoveryPath(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw StoreError.corruptState("absolute predecessor path is forbidden")
        }
        let resolved = recoveryRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard UpdateAtomicFilesystem.isDescendant(resolved, of: recoveryRoot) else {
            throw StoreError.corruptState("predecessor path escapes recovery root")
        }
        return resolved
    }

    private func installApp(from sourceApp: URL) throws {
        guard fm.fileExists(atPath: sourceApp.path) else {
            throw StoreError.filesystem("staged app bundle is missing")
        }
        let liveApp = installRoot.appendingPathComponent("Darkbloom.app")
        try UpdateAtomicFilesystem.replace(sourceApp, at: liveApp)
    }

    /// The live install must be the signed `Darkbloom.app` layout before it
    /// can be snapshotted as rollback material.
    private func requireLiveApp() throws {
        let app = installRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        guard fm.fileExists(atPath: app.appendingPathComponent("darkbloom").path),
              fm.fileExists(atPath: app.appendingPathComponent("mlx.metallib").path)
        else {
            throw StoreError.missingLiveInstall
        }
    }

    private func artifactPaths(
        root: URL
    ) -> (bundle: URL, binary: URL, enclave: URL, metallib: URL) {
        let bundle = root.appendingPathComponent("Darkbloom.app")
        let app = bundle.appendingPathComponent("Contents/MacOS")
        return (
            bundle,
            app.appendingPathComponent("darkbloom"),
            app.appendingPathComponent("darkbloom-enclave"),
            app.appendingPathComponent("mlx.metallib")
        )
    }

    private func stateInstallDateFallback(_ now: Double) -> Double {
        guard let attributes = try? fm.attributesOfItem(
            atPath: installRoot.appendingPathComponent("Darkbloom.app").path
        ), let created = attributes[.creationDate] as? Date
        else {
            return now
        }
        return created.timeIntervalSince1970
    }
}
