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
            at: installRoot.appendingPathComponent(identity.appBundleName),
            to: copied.bundle)

        try verifySignature(bundle: copied.bundle, binary: copied.binary)
        let release = try releaseRecord(
            ofAppIn: nextRoot,
            version: version,
            releaseBundleHash: releaseBundleHash,
            installGeneration: installGeneration,
            installedAt: stateInstallDateFallback(now)
        )
        let manifest = VerifiedPredecessor(
            release: release,
            layout: .app,
            bundlePath: "predecessor/\(identity.appBundleName)",
            binaryPath: "predecessor/\(identity.appBundleName)/Contents/MacOS/\(identity.cliName)",
            enclavePath: "predecessor/\(identity.appBundleName)/Contents/MacOS/\(identity.enclaveName)",
            metallibPath: "predecessor/\(identity.appBundleName)/Contents/MacOS/mlx.metallib",
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

    /// The version an app is signed as: the `CFBundleShortVersionString` of its `Info.plist`, which the release lane
    /// sets to the release version and the code signature seals. Nil when it names none.
    static func signedVersion(ofApp bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty
        else { return nil }
        return version
    }

    /// The version the installed app is signed as (`signedVersion(ofApp:)`).
    func installedSignedVersion() -> String? {
        Self.signedVersion(ofApp: artifactPaths(root: installRoot).bundle)
    }

    /// Whether the installed app is the app `record` names (the hashes `stagingContainsTarget` compares). Nil when it
    /// cannot be read (a file it needs is missing or unreadable): a damaged install is no evidence of another one.
    func installedApp(is record: InstalledReleaseRecord) -> Bool? {
        let paths = artifactPaths(root: installRoot)
        guard [paths.binary, paths.enclave, paths.metallib].allSatisfy({ fm.isReadableFile(atPath: $0.path) }) else {
            return nil
        }
        return try? stagingContainsTarget(installRoot, target: record)
    }

    /// The installed app recorded as the updater records an install it made, as release `version`.
    func installedAppRecord(version: String, generation: UInt64, now: Double) throws -> InstalledReleaseRecord {
        try requireLiveApp()
        return try releaseRecord(
            ofAppIn: installRoot,
            version: version,
            releaseBundleHash: nil,
            installGeneration: generation,
            installedAt: stateInstallDateFallback(now)
        )
    }

    /// Removes the rollback copy. Its tree leaves the predecessor path in one rename, so a death before the delete
    /// finished leaves an orphan the next recovery removes, never a partial copy.
    func removeRollbackCopy() throws {
        guard fm.fileExists(atPath: predecessorRoot.path) else { return }
        let retired = recoveryRoot.appendingPathComponent(
            "\(Self.retiredPredecessorPrefix)\(UUID().uuidString)", isDirectory: true)
        try UpdateAtomicFilesystem.replace(predecessorRoot, at: retired)
        try UpdateAtomicFilesystem.removeDurably(retired)
    }

    func recordForStagedBundle(
        _ staged: SelfUpdater.StagedBundle,
        generation: UInt64,
        now: Double
    ) throws -> InstalledReleaseRecord {
        try releaseRecord(
            ofAppIn: staged.extractedApp.deletingLastPathComponent(),
            version: staged.release.version,
            releaseBundleHash: staged.release.bundleHash,
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
            atPath: installRoot.appendingPathComponent(identity.appBundleName).path
        ) else {
            throw StoreError.filesystem(
                "canonical links requested but \(identity.appBundleName) is missing")
        }
        let bin = installRoot.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let appBin = "../\(identity.appBundleName)/Contents/MacOS"
        for (name, target) in [
            ("mlx.metallib", "\(appBin)/mlx.metallib"),
            (identity.enclaveName, "\(appBin)/\(identity.enclaveName)"),
            (identity.cliName, "\(appBin)/\(identity.cliName)"),
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
        let liveApp = installRoot.appendingPathComponent(identity.appBundleName)
        try UpdateAtomicFilesystem.replace(sourceApp, at: liveApp)
    }

    /// The live install must be the signed `Darkbloom.app` layout before it
    /// can be snapshotted as rollback material.
    private func requireLiveApp() throws {
        let app = installRoot.appendingPathComponent(identity.appBundleName)
            .appendingPathComponent("Contents/MacOS")
        guard fm.fileExists(atPath: app.appendingPathComponent(identity.cliName).path),
              fm.fileExists(atPath: app.appendingPathComponent("mlx.metallib").path)
        else {
            throw StoreError.missingLiveInstall
        }
    }

    /// The record of the app in `root`: the tree hash of the bundle and the hashes of the files
    /// `stagingContainsTarget` and `verifyPredecessor` check.
    private func releaseRecord(
        ofAppIn root: URL,
        version: String,
        releaseBundleHash: String?,
        installGeneration: UInt64,
        installedAt: Double
    ) throws -> InstalledReleaseRecord {
        let paths = artifactPaths(root: root)
        return InstalledReleaseRecord(
            version: version,
            releaseBundleHash: releaseBundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: paths.bundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: paths.binary),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: paths.enclave),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: paths.metallib),
            installGeneration: installGeneration,
            installedAt: installedAt
        )
    }

    private func artifactPaths(
        root: URL
    ) -> (bundle: URL, binary: URL, enclave: URL, metallib: URL) {
        let bundle = root.appendingPathComponent(identity.appBundleName)
        let app = bundle.appendingPathComponent("Contents/MacOS")
        return (
            bundle,
            app.appendingPathComponent(identity.cliName),
            app.appendingPathComponent(identity.enclaveName),
            app.appendingPathComponent("mlx.metallib")
        )
    }

    /// Names of the app and its executables for this build.
    private var identity: BuildEnvironment { BuildEnvironment.current }

    private func stateInstallDateFallback(_ now: Double) -> Double {
        guard let attributes = try? fm.attributesOfItem(
            atPath: installRoot.appendingPathComponent(identity.appBundleName).path
        ), let created = attributes[.creationDate] as? Date
        else {
            return now
        }
        return created.timeIntervalSince1970
    }
}
