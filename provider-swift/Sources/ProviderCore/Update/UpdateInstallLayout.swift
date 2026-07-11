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
        try fm.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: nextRoot)
        try fm.createDirectory(at: nextRoot, withIntermediateDirectories: true)

        let copiedBundle: URL
        let copiedBinary: URL
        let copiedMetallib: URL
        switch layout {
        case .app:
            let source = installRoot.appendingPathComponent("Darkbloom.app")
            copiedBundle = nextRoot.appendingPathComponent("Darkbloom.app")
            try fm.copyItem(at: source, to: copiedBundle)
            copiedBinary = copiedBundle.appendingPathComponent("Contents/MacOS/darkbloom")
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
            copiedBinary = copiedBundle.appendingPathComponent("darkbloom")
            copiedMetallib = copiedBundle.appendingPathComponent("mlx.metallib")
        }

        try verifySignature(layout: layout, bundle: copiedBundle, binary: copiedBinary)
        let release = InstalledReleaseRecord(
            version: version,
            releaseBundleHash: releaseBundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: copiedBundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: copiedBinary),
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
            try? fm.removeItem(at: nextRoot)
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
        let metallib: URL
        if let app = staged.extractedApp {
            bundle = app
            binary = app.appendingPathComponent("Contents/MacOS/darkbloom")
            metallib = app.appendingPathComponent("Contents/MacOS/mlx.metallib")
        } else {
            bundle = staged.stagingRoot.appendingPathComponent("bin")
            binary = staged.flatDarkbloom
            metallib = staged.flatMetallib
        }
        return InstalledReleaseRecord(
            version: staged.release.version,
            releaseBundleHash: staged.release.bundleHash,
            installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: bundle),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: binary),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: metallib),
            installGeneration: generation,
            installedAt: now
        )
    }

    func installStagedBundle(_ staged: SelfUpdater.StagedBundle) throws {
        if let app = staged.extractedApp {
            try installApp(from: app)
        } else {
            try installFlat(
                darkbloom: staged.flatDarkbloom,
                enclave: staged.flatEnclave,
                metallib: staged.flatMetallib
            )
        }
        try ensureCanonicalLinks()
    }

    func installFromStaging(
        _ stagingRoot: URL,
        layout: VerifiedPredecessor.Layout
    ) throws {
        switch layout {
        case .app:
            try installApp(from: stagingRoot.appendingPathComponent("Darkbloom.app"))
        case .flat:
            let bin = stagingRoot.appendingPathComponent("bin")
            try installFlat(
                darkbloom: bin.appendingPathComponent("darkbloom"),
                enclave: bin.appendingPathComponent("darkbloom-enclave"),
                metallib: bin.appendingPathComponent("mlx.metallib")
            )
        }
    }

    func ensureCanonicalLinks() throws {
        guard fm.fileExists(atPath: installRoot.appendingPathComponent("Darkbloom.app").path) else {
            let legacy = installRoot.appendingPathComponent("bin/eigeninference-enclave")
            try UpdateAtomicFilesystem.replaceSymlink(at: legacy, target: "darkbloom-enclave")
            return
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

    func liveMatches(
        _ record: InstalledReleaseRecord,
        layout: VerifiedPredecessor.Layout
    ) throws -> Bool {
        let (binary, metallib) = livePaths(layout: layout)
        guard fm.fileExists(atPath: binary.path), fm.fileExists(atPath: metallib.path) else {
            return false
        }
        guard try UpdateAtomicFilesystem.sha256(file: binary) == record.binaryHash,
              try UpdateAtomicFilesystem.sha256(file: metallib) == record.metallibHash
        else {
            return false
        }
        if layout == .app {
            let app = installRoot.appendingPathComponent("Darkbloom.app")
            guard try UpdateAtomicFilesystem.treeHash(root: app)
                    == record.installedBundleHash
            else {
                return false
            }
            try verifySignature(layout: .app, bundle: app, binary: binary)
            return true
        }
        try verifySignature(
            layout: .flat,
            bundle: installRoot.appendingPathComponent("bin"),
            binary: binary
        )
        return true
    }

    func stagingContainsTarget(
        _ stagingRoot: URL,
        target: InstalledReleaseRecord,
        layout: VerifiedPredecessor.Layout
    ) throws -> Bool {
        let binary: URL
        let metallib: URL
        switch layout {
        case .app:
            let app = stagingRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS")
            binary = app.appendingPathComponent("darkbloom")
            metallib = app.appendingPathComponent("mlx.metallib")
        case .flat:
            let bin = stagingRoot.appendingPathComponent("bin")
            binary = bin.appendingPathComponent("darkbloom")
            metallib = bin.appendingPathComponent("mlx.metallib")
        }
        guard fm.fileExists(atPath: binary.path), fm.fileExists(atPath: metallib.path) else {
            return false
        }
        return try UpdateAtomicFilesystem.sha256(file: binary) == target.binaryHash
            && UpdateAtomicFilesystem.sha256(file: metallib) == target.metallibHash
    }

    func copyPredecessor(
        _ predecessor: VerifiedPredecessor,
        to stagingRoot: URL
    ) throws {
        try? fm.removeItem(at: stagingRoot)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
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
        let metallib: URL
        switch predecessor.layout {
        case .app:
            bundle = stagingRoot.appendingPathComponent("Darkbloom.app")
            binary = bundle.appendingPathComponent("Contents/MacOS/darkbloom")
            metallib = bundle.appendingPathComponent("Contents/MacOS/mlx.metallib")
        case .flat:
            bundle = stagingRoot.appendingPathComponent("bin")
            binary = bundle.appendingPathComponent("darkbloom")
            metallib = bundle.appendingPathComponent("mlx.metallib")
        }
        guard try UpdateAtomicFilesystem.treeHash(root: bundle)
                == predecessor.release.installedBundleHash,
              try UpdateAtomicFilesystem.sha256(file: binary) == predecessor.release.binaryHash,
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
        try ensureCanonicalLinks()
        try? fm.removeItem(at: staging)
    }

    func verifySignature(
        layout: VerifiedPredecessor.Layout,
        bundle: URL,
        binary: URL
    ) throws {
        guard verifyCodeSignatures else { return }
        #if canImport(Darwin)
        let target = layout == .app ? bundle : binary
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = layout == .app
            ? ["--verify", "--deep", "--strict", "--verbose=2", target.path]
            : ["--verify", "--strict", "--verbose=2", target.path]
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw StoreError.predecessorVerificationFailed(
                "could not run codesign: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "codesign exited non-zero"
            throw StoreError.predecessorVerificationFailed(detail)
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

    private func installFlat(darkbloom: URL, enclave: URL, metallib: URL) throws {
        let liveBin = installRoot.appendingPathComponent("bin")
        try fm.createDirectory(at: liveBin, withIntermediateDirectories: true)
        // Switch the executable last. If power is lost midway, the old
        // watchdog binary can replay the journal and converge the layout.
        for (source, name, mode) in [
            (metallib, "mlx.metallib", 0o644),
            (enclave, "darkbloom-enclave", 0o755),
            (darkbloom, "darkbloom", 0o755),
        ] {
            guard fm.fileExists(atPath: source.path) else {
                throw StoreError.filesystem("staged \(name) is missing")
            }
            let destination = liveBin.appendingPathComponent(name)
            try UpdateAtomicFilesystem.replace(source, at: destination)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
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

    private func livePaths(
        layout: VerifiedPredecessor.Layout
    ) -> (binary: URL, metallib: URL) {
        switch layout {
        case .app:
            let app = installRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS")
            return (
                app.appendingPathComponent("darkbloom"),
                app.appendingPathComponent("mlx.metallib")
            )
        case .flat:
            let bin = installRoot.appendingPathComponent("bin")
            return (
                bin.appendingPathComponent("darkbloom"),
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
