// Copyright © 2026 Eigen Labs.
//
// A 0.8.7 → 0.8.9 auto-update left a provider's daemon executing out of an
// `.update-staging-*` bundle. Every local surface stayed green — the daemon
// ran, heartbeats flowed, attestation challenges passed, `doctor` reported 30
// PASS / 0 FAIL — while the coordinator derouted the machine because the
// staged tree's `mlx.metallib` hash matched no registered release. There was
// no check anywhere that a provider is running from the live install.
//
// These pin the classifier that check is built on.

import Foundation
import Testing

@testable import ProviderCore

private let liveApp = "/Users/tim/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom"
private let liveFlat = "/Users/tim/.darkbloom/bin/darkbloom"

@Suite("InstallLocation")
struct InstallLocationTests {

    @Test("a normal .app install is live")
    func appLayoutIsLive() {
        #expect(InstallLocation.classify(executablePath: liveApp) == .live)
    }

    @Test("a normal flat install is live")
    func flatLayoutIsLive() {
        #expect(InstallLocation.classify(executablePath: liveFlat) == .live)
    }

    @Test("every transient update directory is caught, at any depth")
    func transientDirectoriesAreCaught() {
        for prefix in InstallLocation.transientDirPrefixes {
            let directory = "\(prefix)7E4A5C1D-0B2F-4A9E-9C3D-1F2E3D4C5B6A"
            let path = "/Users/tim/.darkbloom/\(directory)/Darkbloom.app/Contents/MacOS/darkbloom"
            #expect(
                InstallLocation.classify(executablePath: path)
                    == .transient(directory: directory),
                "prefix \(prefix)")
        }
    }

    @Test("the flat layout inside a staging tree is caught too")
    func transientFlatLayout() {
        let directory = ".update-staging-7E4A5C1D"
        let path = "/Users/tim/.darkbloom/\(directory)/bin/darkbloom"
        #expect(
            InstallLocation.classify(executablePath: path)
                == .transient(directory: directory))
    }

    @Test("a directory that merely resembles a staging name is left alone")
    func lookalikeDirectoriesAreLive() {
        for name in ["update-staging-x", "darkbloom-update-staging-x", ".updates", ".update"] {
            let path = "/Users/tim/\(name)/bin/darkbloom"
            #expect(InstallLocation.classify(executablePath: path) == .live, name)
        }
    }

    @Test("a nil executable path degrades to live rather than blocking startup")
    func nilExecutablePathIsLive() {
        #expect(InstallLocation.current(executablePath: nil) == .live)
    }

    @Test("remediation names the directory and is silent for a live install")
    func remediationText() throws {
        #expect(InstallLocation.remediation(for: .live) == nil)
        let text = try #require(
            InstallLocation.remediation(for: .transient(directory: ".update-staging-abc")))
        #expect(text.contains(".update-staging-abc"))
        #expect(text.lowercased().contains("reinstall"))
    }

    @Test("isTransient matches the case it names")
    func isTransient() {
        #expect(!InstallLocation.Verdict.live.isTransient)
        #expect(InstallLocation.Verdict.transient(directory: ".update-backup-1").isTransient)
    }

    /// The list must cover every transient directory the updater creates.
    /// Where the updater owns a named constant, this asserts against THAT
    /// constant rather than a copy of the string — a duplicated literal would
    /// only be comparing the implementation to itself.
    @Test("the prefix list references the updater's own constants")
    func prefixesReferenceUpdaterConstants() {
        #expect(InstallLocation.transientDirPrefixes.contains(SelfUpdater.stagingDirPrefix))
        #expect(
            InstallLocation.transientDirPrefixes.contains(
                UpdateRecoveryStore.staleAppAsidePrefix))
    }

    /// The inline-constructed names, each with its single construction site.
    /// Adding one to the updater without adding it here reopens the hole; the
    /// literals are unavoidable because the updater builds them inline.
    @Test("the prefix list covers the inline-constructed transient directories")
    func prefixesCoverInlineNames() {
        for prefix in [
            ".update-backup-",  // SelfUpdater backup swap
            ".rollback-staging-",  // UpdateRecoveryStore.rollbackToPredecessor
            ".recovery-restore-",  // UpdateRecoveryStore.restore
            ".predecessor-next-",  // UpdateInstallLayout.snapshotLiveAsPredecessor
        ] {
            #expect(InstallLocation.transientDirPrefixes.contains(prefix), prefix)
        }
    }

    /// The stale-app aside prefix was missing from the first version of this
    /// list, so pin the behaviour that depends on it.
    @Test("a process inside a retired stale-app directory is caught")
    func staleAppAsideIsCaught() {
        let directory = "\(UpdateRecoveryStore.staleAppAsidePrefix)7E4A5C1D"
        let path = "/Users/tim/.darkbloom/\(directory)/Darkbloom.app/Contents/MacOS/darkbloom"
        #expect(
            InstallLocation.classify(executablePath: path)
                == .transient(directory: directory))
    }
}
