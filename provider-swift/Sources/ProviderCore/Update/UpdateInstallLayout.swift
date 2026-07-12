import Foundation

/// Concrete app/flat-layout operations used by the journaled recovery store.
/// Kept separate from transaction/state orchestration so rename ordering and
/// artifact verification remain independently auditable.
extension UpdateRecoveryStore {
    func snapshotLiveAsPredecessor(
        version: String,
        releaseBundleHash: String?,
        installGeneration: UInt64,
        now: Double
    ) throws -> VerifiedPredecessor {
        let layout = try liveLayout()
        let nextRoot = recoveryRoot.appendingPathComponent(
            ".predecessor-next-\(UUID().uuidString)",
            isDirectory: true
        )
        try UpdateAtomicFilesystem.createDirectoryDurably(recoveryRoot)
        try UpdateAtomicFilesystem.removeDurably(nextRoot)
        try UpdateAtomicFilesystem.createDirectoryDurably(nextRoot)

        let copiedBundle: URL
        let copiedBinary: URL
        let copiedEnclave: URL
        let copiedMetallib: URL
        switch layout {
        case .app:
            let source = installRoot.appendingPathComponent("Darkbloom.app")
            copiedBundle = nextRoot.appendingPathComponent("Darkbloom.app")
            try fm.copyItem(at: source, to: copiedBundle)
            copiedBinary = copiedBundle.appendingPathComponent("Contents/MacOS/darkbloom")
            copiedEnclave = copiedBundle.appendingPathComponent("Contents/MacOS/darkbloom-enclave")
            copiedMetallib = copiedBundle.appendingPathComponent("Contents/MacOS/mlx.metallib")
        case .flat:
            let sourceBin = installRoot.appendingPathComponent("bin")
            copiedBundle = nextRoot.appendingPathComponent("bin")
            try fm.createDirectory(at: copiedBundle, withIntermediateDirectories: true)
            for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
                try fm.copyItem(
                    at: sourceBin.appendingPathComponent(name),
                    to: copiedBundle.appendingPathComponent(name)
                )
            }
            // The snapshot must hash the EXACT tree a restore produces.
            // Every flat restore runs `ensureCanonicalLinks(.flat)`, which
            // (re)creates the legacy `eigeninference-enclave` symlink, and
            // `treeHash` includes symlink entries — a record without it would
            // fail the post-restore `liveMatches` verification forever and
            // wedge interrupted-transaction recovery on flat hosts.
            try UpdateAtomicFilesystem.replaceSymlink(
                at: copiedBundle.appendingPathComponent("eigeninference-enclave"),
                target: "darkbloom-enclave"
            )
            copiedBinary = copiedBundle.appendingPathComponent("darkbloom")
            copiedEnclave = copiedBundle.appendingPathComponent("darkbloom-enclave")
            copiedMetallib = copiedBundle.appendingPathComponent("mlx.metallib")
        }

        try verifySignature(layout: layout, bundle: copiedBundle, binary: copiedBinary)
        let release = InstalledReleaseRecord(
            version: version,
            releaseBundleHash: releaseBundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: copiedBundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: copiedBinary),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: copiedEnclave),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: copiedMetallib),
            installGeneration: installGeneration,
            installedAt: stateInstallDateFallback(now)
        )
        let manifest = VerifiedPredecessor(
            release: release,
            layout: layout,
            bundlePath: layout == .app
                ? "predecessor/Darkbloom.app"
                : "predecessor/bin",
            binaryPath: layout == .app
                ? "predecessor/Darkbloom.app/Contents/MacOS/darkbloom"
                : "predecessor/bin/darkbloom",
            enclavePath: layout == .app
                ? "predecessor/Darkbloom.app/Contents/MacOS/darkbloom-enclave"
                : "predecessor/bin/darkbloom-enclave",
            metallibPath: layout == .app
                ? "predecessor/Darkbloom.app/Contents/MacOS/mlx.metallib"
                : "predecessor/bin/mlx.metallib",
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
        let bundle: URL
        let binary: URL
        let enclave: URL
        let metallib: URL
        if let app = staged.extractedApp {
            bundle = app
            binary = app.appendingPathComponent("Contents/MacOS/darkbloom")
            enclave = app.appendingPathComponent("Contents/MacOS/darkbloom-enclave")
            metallib = app.appendingPathComponent("Contents/MacOS/mlx.metallib")
        } else {
            bundle = staged.stagingRoot.appendingPathComponent("bin")
            binary = staged.flatDarkbloom
            enclave = staged.flatEnclave
            metallib = staged.flatMetallib
        }
        return InstalledReleaseRecord(
            version: staged.release.version,
            releaseBundleHash: staged.release.bundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: bundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: binary),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: enclave),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: metallib),
            installGeneration: generation,
            installedAt: now
        )
    }

    func installStagedBundle(_ staged: SelfUpdater.StagedBundle) throws {
        if let app = staged.extractedApp {
            try installApp(from: app)
            try ensureCanonicalLinks(layout: .app)
        } else {
            try installFlatDirectory(
                from: staged.stagingRoot.appendingPathComponent("bin")
            )
            try ensureCanonicalLinks(layout: .flat)
        }
    }

    func installFromStaging(
        _ stagingRoot: URL,
        layout: VerifiedPredecessor.Layout
    ) throws {
        switch layout {
        case .app:
            try installApp(from: stagingRoot.appendingPathComponent("Darkbloom.app"))
        case .flat:
            try installFlatDirectory(
                from: stagingRoot.appendingPathComponent("bin")
            )
        }
    }

    /// Point the canonical `bin/` entries at the just-installed layout.
    ///
    /// The intended layout is passed EXPLICITLY rather than inferred from
    /// whether `Darkbloom.app` happens to exist: after a flat rollback that
    /// followed a `.app` candidate, a stale `Darkbloom.app` is still on disk,
    /// and inferring `.app` would re-point `bin/darkbloom` back into the
    /// quarantined candidate (and let `liveLayout()` later re-adopt it as a
    /// predecessor). For a `.flat` layout we therefore first retire any stale
    /// `Darkbloom.app` and leave `bin/`'s real flat binaries in place.
    func ensureCanonicalLinks(layout: VerifiedPredecessor.Layout) throws {
        switch layout {
        case .flat:
            try removeStaleAppBundle()
            let legacy = installRoot.appendingPathComponent("bin/eigeninference-enclave")
            try UpdateAtomicFilesystem.replaceSymlink(at: legacy, target: "darkbloom-enclave")
        case .app:
            guard fm.fileExists(
                atPath: installRoot.appendingPathComponent("Darkbloom.app").path
            ) else {
                throw StoreError.filesystem(
                    "app layout requested for canonical links but Darkbloom.app is missing")
            }
            let bin = installRoot.appendingPathComponent("bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let appBin = "../Darkbloom.app/Contents/MacOS"
            for (name, target) in [
                ("mlx.metallib", "\(appBin)/mlx.metallib"),
                ("darkbloom-enclave", "\(appBin)/darkbloom-enclave"),
                ("eigeninference-enclave", "darkbloom-enclave"),
                ("darkbloom", "\(appBin)/darkbloom"),
            ] {
                try UpdateAtomicFilesystem.replaceSymlink(
                    at: bin.appendingPathComponent(name),
                    target: target
                )
            }
        }
    }

    /// Retire a `Darkbloom.app` left over from a prior `.app` candidate before
    /// a flat install/rollback links or snapshots the tree. Orphaned aside
    /// copies from an interrupted prior removal are swept first (the whole
    /// operation runs under the update lock, so the sweep is race-free).
    private func removeStaleAppBundle() throws {
        if let entries = try? fm.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries
            where entry.lastPathComponent.hasPrefix(Self.staleAppAsidePrefix) {
                try? fm.removeItem(at: entry)
            }
        }
        let app = installRoot.appendingPathComponent("Darkbloom.app")
        guard UpdateAtomicFilesystem.itemExists(app) else { return }
        try UpdateAtomicFilesystem.atomicRemove(
            app,
            asidePrefix: Self.staleAppAsidePrefix
        )
    }

    static let staleAppAsidePrefix = ".stale-app-"

    func liveMatches(
        _ record: InstalledReleaseRecord,
        layout: VerifiedPredecessor.Layout
    ) throws -> Bool {
        let paths = artifactPaths(root: installRoot, layout: layout)
        guard fm.fileExists(atPath: paths.binary.path),
              fm.fileExists(atPath: paths.enclave.path),
              fm.fileExists(atPath: paths.metallib.path)
        else {
            return false
        }
        guard try UpdateAtomicFilesystem.sha256(file: paths.binary) == record.binaryHash,
              try UpdateAtomicFilesystem.sha256(file: paths.enclave) == record.enclaveHash,
              try UpdateAtomicFilesystem.sha256(file: paths.metallib) == record.metallibHash,
              try UpdateAtomicFilesystem.treeHash(root: paths.bundle)
                == record.installedBundleHash
        else {
            return false
        }
        try verifySignature(
            layout: layout,
            bundle: paths.bundle,
            binary: paths.binary
        )
        return true
    }

    func stagingContainsTarget(
        _ stagingRoot: URL,
        target: InstalledReleaseRecord,
        layout: VerifiedPredecessor.Layout
    ) throws -> Bool {
        let paths = artifactPaths(root: stagingRoot, layout: layout)
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
        switch predecessor.layout {
        case .app:
            let source = try resolvedRecoveryPath(predecessor.bundlePath)
            try fm.copyItem(
                at: source,
                to: stagingRoot.appendingPathComponent("Darkbloom.app")
            )
        case .flat:
            let source = try resolvedRecoveryPath(predecessor.bundlePath)
            try fm.copyItem(at: source, to: stagingRoot.appendingPathComponent("bin"))
        }
        try UpdateAtomicFilesystem.fsyncTree(stagingRoot)
    }

    func verifyStagedPredecessor(
        _ predecessor: VerifiedPredecessor,
        at stagingRoot: URL
    ) throws {
        let bundle: URL
        let binary: URL
        let enclave: URL
        let metallib: URL
        switch predecessor.layout {
        case .app:
            bundle = stagingRoot.appendingPathComponent("Darkbloom.app")
            binary = bundle.appendingPathComponent("Contents/MacOS/darkbloom")
            enclave = bundle.appendingPathComponent("Contents/MacOS/darkbloom-enclave")
            metallib = bundle.appendingPathComponent("Contents/MacOS/mlx.metallib")
        case .flat:
            bundle = stagingRoot.appendingPathComponent("bin")
            binary = bundle.appendingPathComponent("darkbloom")
            enclave = bundle.appendingPathComponent("darkbloom-enclave")
            metallib = bundle.appendingPathComponent("mlx.metallib")
        }
        guard try UpdateAtomicFilesystem.treeHash(root: bundle)
                == predecessor.release.installedBundleHash,
              try UpdateAtomicFilesystem.sha256(file: binary) == predecessor.release.binaryHash,
              try UpdateAtomicFilesystem.sha256(file: enclave) == predecessor.release.enclaveHash,
              try UpdateAtomicFilesystem.sha256(file: metallib) == predecessor.release.metallibHash
        else {
            throw StoreError.predecessorVerificationFailed(
                "rollback staging copy changed during copy")
        }
        try verifySignature(layout: predecessor.layout, bundle: bundle, binary: binary)
    }

    func restorePredecessorCopy(
        _ predecessor: VerifiedPredecessor,
        stagingName: String
    ) throws {
        let staging = installRoot.appendingPathComponent(stagingName, isDirectory: true)
        try copyPredecessor(predecessor, to: staging)
        try verifyStagedPredecessor(predecessor, at: staging)
        try installFromStaging(staging, layout: predecessor.layout)
        try ensureCanonicalLinks(layout: predecessor.layout)
        try UpdateAtomicFilesystem.removeDurably(staging)
    }

    /// INTENTIONALLY FAIL-CLOSED for legacy flat/ad-hoc installs: an install
    /// whose live binary does not satisfy the pinned Darkbloom designated
    /// requirement (Team SLDQ2GJ6TL) is not eligible as rollback material and
    /// its replay/rollback verification refuses. Accepting a structurally
    /// valid but unpinned signature would let any locally re-signed binary
    /// become "verified" recovery state. Fleet impact and the recorded
    /// decision live in the threat model (T-043); the remedy for an affected
    /// host is a signed reinstall via install.sh.
    func verifySignature(
        layout: VerifiedPredecessor.Layout,
        bundle: URL,
        binary: URL
    ) throws {
        guard verifyCodeSignatures else { return }
        #if canImport(Darwin)
        let target = layout == .app ? bundle : binary
        do {
            try DarkbloomCodeSignature.verify(
                target,
                deep: layout == .app
            )
            if layout == .app {
                try FanHelperCapabilityVerifier.verify(
                    app: bundle,
                    executable: binary,
                    signaturePolicy: .darkbloomProduction
                )
            }
        } catch {
            throw StoreError.predecessorVerificationFailed(
                "\(target.lastPathComponent) does not satisfy the pinned Darkbloom "
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

    private func installFlatDirectory(from stagedBin: URL) throws {
        let liveBin = installRoot.appendingPathComponent("bin")
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            guard fm.fileExists(
                atPath: stagedBin.appendingPathComponent(name).path
            ) else {
                throw StoreError.filesystem("staged \(name) is missing")
            }
        }
        try UpdateAtomicFilesystem.replace(stagedBin, at: liveBin)
    }

    private func liveLayout() throws -> VerifiedPredecessor.Layout {
        let app = installRoot.appendingPathComponent("Darkbloom.app")
        if fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/darkbloom").path),
           fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/mlx.metallib").path)
        {
            return .app
        }
        let bin = installRoot.appendingPathComponent("bin")
        if fm.fileExists(atPath: bin.appendingPathComponent("darkbloom").path),
           fm.fileExists(atPath: bin.appendingPathComponent("darkbloom-enclave").path),
           fm.fileExists(atPath: bin.appendingPathComponent("mlx.metallib").path)
        {
            return .flat
        }
        throw StoreError.missingLiveInstall
    }

    private func artifactPaths(
        root: URL,
        layout: VerifiedPredecessor.Layout
    ) -> (bundle: URL, binary: URL, enclave: URL, metallib: URL) {
        switch layout {
        case .app:
            let bundle = root.appendingPathComponent("Darkbloom.app")
            let app = bundle.appendingPathComponent("Contents/MacOS")
            return (
                bundle,
                app.appendingPathComponent("darkbloom"),
                app.appendingPathComponent("darkbloom-enclave"),
                app.appendingPathComponent("mlx.metallib")
            )
        case .flat:
            let bin = root.appendingPathComponent("bin")
            return (
                bin,
                bin.appendingPathComponent("darkbloom"),
                bin.appendingPathComponent("darkbloom-enclave"),
                bin.appendingPathComponent("mlx.metallib")
            )
        }
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
