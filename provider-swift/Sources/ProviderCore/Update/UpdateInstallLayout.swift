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
        let modes = try UpdateArtifactModes(
            binary: copiedBinary,
            enclave: copiedEnclave,
            metallib: copiedMetallib
        )
        if let payload = modes.nonExecutablePayload {
            throw StoreError.predecessorVerificationFailed(
                "installed predecessor payload \(payload) is not executable"
            )
        }
        let release = InstalledReleaseRecord(
            version: version,
            releaseBundleHash: releaseBundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: copiedBundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: copiedBinary),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: copiedEnclave),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: copiedMetallib),
            binaryMode: modes.binary,
            enclaveMode: modes.enclave,
            metallibMode: modes.metallib,
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
        let modes = try UpdateArtifactModes(
            binary: binary,
            enclave: enclave,
            metallib: metallib
        )
        guard modes == staged.artifactModes else {
            throw StoreError.filesystem(
                "staged payload permissions changed before transaction commit"
            )
        }
        if let payload = modes.nonExecutablePayload {
            throw StoreError.filesystem(
                "staged release payload \(payload) is not executable"
            )
        }
        let installedBundleHash = try UpdateAtomicFilesystem.treeHash(
            root: bundle
        )
        guard installedBundleHash == staged.stagedTreeHash else {
            throw StoreError.filesystem(
                "staged payload changed before transaction commit"
            )
        }
        return InstalledReleaseRecord(
            version: staged.release.version,
            releaseBundleHash: staged.release.bundleHash,
            installedBundleHash: installedBundleHash,
            binaryHash: try UpdateAtomicFilesystem.sha256(file: binary),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: enclave),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: metallib),
            binaryMode: modes.binary,
            enclaveMode: modes.enclave,
            metallibMode: modes.metallib,
            installGeneration: generation,
            installedAt: now
        )
    }

    func installStagedBundle(
        _ staged: SelfUpdater.StagedBundle,
        validatedSource: RecoveryLayoutSnapshot
    ) throws {
        let layout: VerifiedPredecessor.Layout =
            staged.extractedApp == nil ? .flat : .app
        try installFromStaging(
            staged.stagingRoot,
            layout: layout,
            validatedSource: validatedSource
        )
    }

    func installFromStaging(
        _ stagingRoot: URL,
        layout: VerifiedPredecessor.Layout,
        validatedSource: RecoveryLayoutSnapshot
    ) throws {
        let paths = artifactPaths(root: stagingRoot, layout: layout)
        guard validatedSource.component.url == paths.bundle.standardizedFileURL else {
            throw StoreError.corruptTransaction(
                "validated staging component does not match the promoted path")
        }
        try validatedSource.assertUnchanged()
        let mutation = try recoveryMutationGuard(layout: layout)
        try mutation.assertUnchanged()

        switch layout {
        case .app:
            try installApp(
                from: paths.bundle,
                sourceIdentity: validatedSource.component.identity,
                destinationIdentity: mutation.destination.identity
            )
        case .flat:
            try installFlatDirectory(
                from: paths.bundle,
                sourceIdentity: validatedSource.component.identity,
                destinationIdentity: mutation.destination.identity
            )
        }

        guard let promoted = try validatedRecoveryLayout(
            root: installRoot,
            layout: layout,
            context: "promoted live \(layout.rawValue)"
        ), promoted.component.identity == validatedSource.component.identity else {
            throw StoreError.corruptTransaction(
                "promoted component is not the validated staging node")
        }
        try promoted.assertUnchanged()
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
        guard let live = try validatedRecoveryLayout(
            root: installRoot,
            layout: layout,
            context: "canonical-link live \(layout.rawValue)"
        ), live.payloadsAreRegularFiles else {
            throw StoreError.filesystem(
                "\(layout.rawValue) layout is incomplete before canonical-link repair")
        }
        let mutation = try recoveryMutationGuard(layout: layout)
        guard mutation.destination.identity == live.component.identity else {
            throw StoreError.corruptTransaction(
                "live component changed before canonical-link repair")
        }
        try live.assertUnchanged()
        try mutation.assertUnchanged()

        switch layout {
        case .flat:
            if let staleApp = mutation.staleApp,
               let identity = staleApp.identity
            {
                try UpdateAtomicFilesystem.atomicRemove(
                    staleApp.url,
                    asidePrefix: Self.staleAppAsidePrefix,
                    expectedIdentity: identity
                )
            }
            try live.assertUnchanged()
            let legacy = installRoot.appendingPathComponent("bin/eigeninference-enclave")
            try UpdateAtomicFilesystem.requireIdentity(
                live.component.identity,
                at: live.component.url,
                operation: "flat bin changed before canonical-link repair"
            )
            try UpdateAtomicFilesystem.replaceSymlink(
                at: legacy,
                target: "darkbloom-enclave",
                expectedDirectory: live.component.identity
            )
        case .app:
            let bin = installRoot.appendingPathComponent("bin")
            var binSnapshot = mutation.canonicalBin
            if binSnapshot?.identity == nil {
                try mutation.installRoot.assertUnchanged()
                do {
                    try fm.createDirectory(
                        at: bin,
                        withIntermediateDirectories: false
                    )
                } catch {
                    throw StoreError.corruptTransaction(
                        "canonical bin path appeared while creating it")
                }
                binSnapshot = try optionalCanonicalBinSnapshot(bin)
            }
            guard let binSnapshot,
                  let binIdentity = binSnapshot.identity,
                  binIdentity.kind == .directory
            else {
                throw StoreError.corruptTransaction(
                    "canonical bin directory is unavailable")
            }
            let appBin = "../Darkbloom.app/Contents/MacOS"
            for (name, target) in [
                ("mlx.metallib", "\(appBin)/mlx.metallib"),
                ("darkbloom-enclave", "\(appBin)/darkbloom-enclave"),
                ("eigeninference-enclave", "darkbloom-enclave"),
                ("darkbloom", "\(appBin)/darkbloom"),
            ] {
                try live.assertUnchanged()
                try UpdateAtomicFilesystem.requireIdentity(
                    binIdentity,
                    at: bin,
                    operation: "canonical bin changed before symlink repair"
                )
                try UpdateAtomicFilesystem.replaceSymlink(
                    at: bin.appendingPathComponent(name),
                    target: target,
                    expectedDirectory: binIdentity
                )
            }
        }
    }

    static let staleAppAsidePrefix = ".stale-app-"

    func liveMatches(
        _ record: InstalledReleaseRecord,
        layout: VerifiedPredecessor.Layout
    ) throws -> Bool {
        try matchingLayoutSnapshot(
            installRoot,
            target: record,
            layout: layout,
            context: "live \(layout.rawValue)",
            verifySignature: true,
            allowCanonicalAppLinksForFlatLive: true
        ) != nil
    }

    func stagingContainsTarget(
        _ stagingRoot: URL,
        target: InstalledReleaseRecord,
        layout: VerifiedPredecessor.Layout
    ) throws -> Bool {
        try matchingLayoutSnapshot(
            stagingRoot,
            target: target,
            layout: layout,
            context: "journal staging",
            verifySignature: false
        ) != nil
    }

    func matchingLayoutSnapshot(
        _ root: URL,
        target: InstalledReleaseRecord,
        layout: VerifiedPredecessor.Layout,
        context: String,
        verifySignature shouldVerifySignature: Bool,
        allowCanonicalAppLinksForFlatLive: Bool = false
    ) throws -> RecoveryLayoutSnapshot? {
        guard let paths = try validatedRecoveryLayout(
            root: root,
            layout: layout,
            context: context,
            allowCanonicalAppLinksForFlatLive:
                allowCanonicalAppLinksForFlatLive
        ) else {
            return nil
        }
        try paths.assertUnchanged()
        guard paths.payloadsAreRegularFiles else {
            return nil
        }
        let modes = try UpdateArtifactModes(
            binary: paths.binary,
            enclave: paths.enclave,
            metallib: paths.metallib
        )
        guard modes.nonExecutablePayload == nil,
              modes.matches(target)
        else {
            return nil
        }
        guard try UpdateAtomicFilesystem.sha256(file: paths.binary)
                == target.binaryHash,
              try UpdateAtomicFilesystem.sha256(file: paths.enclave)
                == target.enclaveHash,
              try UpdateAtomicFilesystem.sha256(file: paths.metallib)
                == target.metallibHash,
              try UpdateAtomicFilesystem.treeHash(root: paths.component.url)
                == target.installedBundleHash
        else {
            return nil
        }
        try paths.assertUnchanged()
        if shouldVerifySignature {
            try verifySignature(
                layout: layout,
                bundle: paths.component.url,
                binary: paths.binary
            )
            try paths.assertUnchanged()
        }
        return paths
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

    @discardableResult
    func verifyStagedPredecessor(
        _ predecessor: VerifiedPredecessor,
        at stagingRoot: URL
    ) throws -> RecoveryLayoutSnapshot {
        guard let snapshot = try matchingLayoutSnapshot(
            stagingRoot,
            target: predecessor.release,
            layout: predecessor.layout,
            context: "rollback staging",
            verifySignature: true
        ) else {
            throw StoreError.predecessorVerificationFailed(
                "rollback staging copy changed during copy")
        }
        return snapshot
    }

    func restorePredecessorCopy(
        _ predecessor: VerifiedPredecessor,
        stagingName: String
    ) throws {
        let staging = installRoot.appendingPathComponent(stagingName, isDirectory: true)
        try copyPredecessor(predecessor, to: staging)
        let stagingRoot = try recoveryNodeSnapshot(
            at: staging,
            label: "predecessor restore staging root"
        )
        guard stagingRoot.identity?.kind == .directory else {
            throw StoreError.corruptTransaction(
                "predecessor restore staging root is not a directory")
        }
        let stagedPredecessor = try verifyStagedPredecessor(
            predecessor,
            at: staging
        )
        try installFromStaging(
            staging,
            layout: predecessor.layout,
            validatedSource: stagedPredecessor
        )
        guard try liveMatches(
            predecessor.release,
            layout: predecessor.layout
        ) else {
            throw StoreError.predecessorVerificationFailed(
                "restored predecessor changed during promotion")
        }
        try ensureCanonicalLinks(layout: predecessor.layout)
        guard try liveMatches(
            predecessor.release,
            layout: predecessor.layout
        ) else {
            throw StoreError.predecessorVerificationFailed(
                "restored predecessor changed during canonical-link repair")
        }
        try stagingRoot.assertUnchanged()
        if let identity = stagingRoot.identity {
            try UpdateAtomicFilesystem.removeDurably(
                staging,
                expectedIdentity: identity
            )
        }
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

    private func installApp(
        from sourceApp: URL,
        sourceIdentity: UpdateAtomicFilesystem.ItemIdentity?,
        destinationIdentity: UpdateAtomicFilesystem.ItemIdentity?
    ) throws {
        guard let sourceIdentity, sourceIdentity.kind == .directory else {
            throw StoreError.corruptTransaction(
                "validated staged app bundle identity is missing")
        }
        let liveApp = installRoot.appendingPathComponent("Darkbloom.app")
        try UpdateAtomicFilesystem.replace(
            sourceApp,
            at: liveApp,
            expectedSource: sourceIdentity,
            expectedDestination: destinationIdentity
        )
    }

    private func installFlatDirectory(
        from stagedBin: URL,
        sourceIdentity: UpdateAtomicFilesystem.ItemIdentity?,
        destinationIdentity: UpdateAtomicFilesystem.ItemIdentity?
    ) throws {
        guard let sourceIdentity, sourceIdentity.kind == .directory else {
            throw StoreError.corruptTransaction(
                "validated staged flat directory identity is missing")
        }
        let liveBin = installRoot.appendingPathComponent("bin")
        try UpdateAtomicFilesystem.replace(
            stagedBin,
            at: liveBin,
            expectedSource: sourceIdentity,
            expectedDestination: destinationIdentity
        )
    }

    private func optionalCanonicalBinSnapshot(
        _ bin: URL
    ) throws -> RecoveryNodeSnapshot {
        let snapshot = try recoveryNodeSnapshot(
            at: bin,
            label: "canonical bin directory"
        )
        if let identity = snapshot.identity, identity.kind != .directory {
            throw StoreError.corruptTransaction(
                "canonical bin path is not a directory")
        }
        return snapshot
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
