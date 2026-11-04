/// A Mac whose update record no longer describes its install: the official installer replaced `Darkbloom.app` and never
/// touched `recovery/state.json` (the M5 Max of the pair-2 validation, 2026-11-03). The cluster service supervisor must
/// not act on releases that are not installed. Temporary install roots with fixture apps whose `Info.plist` names
/// their version, as a signed release's does; the release check is answered in-process (no socket); no launchd, no
/// `~/.darkbloom`, and no process but the `tar` the updater's own staging runs.

import Foundation
import Testing
@testable import ProviderCore

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ line: String) { lock.withLock { values.append(line) } }
    var all: [String] { lock.withLock { values } }
}

/// Answers the release check with the release its host names (`release-<version>.invalid`), and a download with the
/// same small body, whose hash matches no release: nothing is ever installed from here.
private final class LatestReleaseProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LatestReleaseProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host, host.hasPrefix("release-"), host.hasSuffix(".invalid") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let version = host.dropFirst("release-".count).dropLast(".invalid".count)
        let body = #"{"version":"\#(version)","platform":"macos-arm64","url":"http://\#(host)/bundle.tar.gz","bundle_hash":"\#(String(repeating: "a", count: 64))"}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// One Mac's install root as `UpdateRecoveryStore` lays it out.
private struct InstalledMac {
    let root: URL
    var installRoot: URL { root.appendingPathComponent("install", isDirectory: true) }
    var app: URL { installRoot.appendingPathComponent("Darkbloom.app", isDirectory: true) }
    var rollbackCopy: URL { installRoot.appendingPathComponent("recovery/predecessor", isDirectory: true) }
    var store: UpdateRecoveryStore { UpdateRecoveryStore(installRoot: installRoot, verifyCodeSignatures: false) }

    /// The installer's layout: `Darkbloom.app` of `version` and the `bin/` links, and no update record.
    init(installed version: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("update-record-\(UUID().uuidString)", isDirectory: true)
        try Self.writeApp(version: version, at: app)
        let bin = installRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(name).path,
                                                       withDestinationPath: "../Darkbloom.app/Contents/MacOS/\(name)")
        }
    }

    /// The M5 Max: official 0.10.7 is installed, but the record says 0.9.22 is installed, 0.10.6 is pending with the
    /// launch attempt the 23:20:07Z start opened, and the rollback copy is recorded as 0.9.22 although it is a 0.10.2
    /// app that passes every check.
    static func reinstalledOverAStaleRecord() throws -> InstalledMac {
        let mac = try InstalledMac(installed: "0.10.7")
        let copy = try mac.keepRollbackCopy(signed: "0.10.2", recordedAs: "0.9.22", generation: 1)
        let pending = PendingReleaseCandidate(release: try mac.record(ofReleaseNotOnDisk: "0.10.6", generation: 2),
                                              failureCount: 0, pendingAttemptID: "attempt-2026-11-03T23:20:07Z",
                                              attemptStartedAt: 1_793_748_007)
        try mac.store.writeState(UpdateRecoveryState(installGeneration: 2,
            current: try mac.record(ofReleaseNotOnDisk: "0.9.22", generation: 1), candidate: pending, predecessor: copy))
        return mac
    }

    /// The validator's case: 0.10.8 installed by an earlier updater over 0.10.7, which `install.sh` had put in place
    /// while the record said 0.10.6. The copy is the 0.10.7 app, recorded as 0.10.6; 0.10.8 is pending.
    static func updatedOverAMislabelledCopy(copyNamesVersion: Bool = true) throws -> InstalledMac {
        let mac = try InstalledMac(installed: "0.10.8")
        let copy = try mac.keepRollbackCopy(signed: "0.10.7", recordedAs: "0.10.6", generation: 1, namesVersion: copyNamesVersion)
        let pending = PendingReleaseCandidate(release: try record(of: mac.app, version: "0.10.8", generation: 2), failureCount: 0)
        try mac.store.writeState(UpdateRecoveryState(installGeneration: 2,
            current: try mac.record(ofReleaseNotOnDisk: "0.10.6", generation: 1), candidate: pending, predecessor: copy))
        return mac
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// The updater of the build this Mac runs; the coordinator's latest release is `latest`.
    func updater(running: String, latest: String = "0.0.1") -> SelfUpdater {
        SelfUpdater(coordinatorBaseURL: "http://release-\(latest).invalid", installRoot: installRoot, verifyCodeSignatures: false,
                    currentVersion: running, urlSession: LatestReleaseProtocol.session(), now: { 1_000 })
    }

    func installedBinary() throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/MacOS/darkbloom"), encoding: .utf8)
    }

    func stagingDirectories() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: installRoot.path)) ?? []).filter { $0.hasPrefix(".update-staging-") }
    }

    /// The release tarball of `version` (its `Darkbloom.app` and the flat verifier copies), as the coordinator serves it.
    func release(_ version: String) throws -> (tarball: URL, info: ReleaseInfo) {
        let source = root.appendingPathComponent("release-\(version)", isDirectory: true)
        try Self.writeApp(version: version, at: source.appendingPathComponent("Darkbloom.app"))
        let flat = source.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent("Darkbloom.app/Contents/MacOS/\(name)"),
                                             to: flat.appendingPathComponent(name))
        }
        let tarball = root.appendingPathComponent("release-\(version).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", tarball.path, "-C", source.path, "."]
        try tar.run()
        tar.waitUntilExit()
        let hash = try UpdateAtomicFilesystem.sha256(file: tarball)
        return (tarball, ReleaseInfo(version: version, platform: "macos-arm64", url: "file:///unused", bundleHash: hash))
    }

    /// The rollback copy: the app of `signed` (what its `Info.plist` and binary say), recorded as `recordedAs`.
    func keepRollbackCopy(signed: String, recordedAs: String, generation: UInt64,
                          namesVersion: Bool = true) throws -> VerifiedPredecessor {
        let bundle = rollbackCopy.appendingPathComponent("Darkbloom.app", isDirectory: true)
        try Self.writeApp(version: signed, at: bundle, namesVersion: namesVersion)
        let copy = VerifiedPredecessor(
            release: try Self.record(of: bundle, version: recordedAs, generation: generation), layout: .app,
            bundlePath: "predecessor/Darkbloom.app", binaryPath: "predecessor/Darkbloom.app/Contents/MacOS/darkbloom",
            enclavePath: "predecessor/Darkbloom.app/Contents/MacOS/darkbloom-enclave",
            metallibPath: "predecessor/Darkbloom.app/Contents/MacOS/mlx.metallib", verifiedAt: 1_793_468_036)
        try UpdateAtomicFilesystem.writeJSON(copy, to: rollbackCopy.appendingPathComponent("manifest.json"))
        return copy
    }

    /// The record of a release this Mac no longer has on disk.
    func record(ofReleaseNotOnDisk version: String, generation: UInt64) throws -> InstalledReleaseRecord {
        let scratch = root.appendingPathComponent("gone-\(version)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Self.writeApp(version: version, at: scratch.appendingPathComponent("Darkbloom.app"))
        return try Self.record(of: scratch.appendingPathComponent("Darkbloom.app"), version: version, generation: generation)
    }

    /// The record the updater keeps of `app`, labelled `version`.
    static func record(of app: URL, version: String, generation: UInt64) throws -> InstalledReleaseRecord {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        return InstalledReleaseRecord(
            version: version, releaseBundleHash: nil, installedBundleHash: try UpdateAtomicFilesystem.treeHash(root: app),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: macOS.appendingPathComponent("darkbloom")),
            enclaveHash: try UpdateAtomicFilesystem.sha256(file: macOS.appendingPathComponent("darkbloom-enclave")),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: macOS.appendingPathComponent("mlx.metallib")),
            installGeneration: generation, installedAt: 1_793_000_000)
    }

    /// An app whose `Info.plist` names its version, as a signed release's does (unless `namesVersion` is false).
    static func writeApp(version: String, at app: URL, namesVersion: Bool = true) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "io.darkbloom.provider", "CFBundleExecutable": "darkbloom"]
        if namesVersion {
            info["CFBundleShortVersionString"] = version
            info["CFBundleVersion"] = version
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("\(version)-darkbloom".utf8).write(to: macOS.appendingPathComponent("darkbloom"))
        try Data("\(version)-enclave".utf8).write(to: macOS.appendingPathComponent("darkbloom-enclave"))
        try Data("\(version)-metallib".utf8).write(to: macOS.appendingPathComponent("mlx.metallib"))
    }
}

private func isUpToDate(_ result: UpdateCheckResult, at version: String) -> Bool {
    if case .upToDate(let current) = result { return current == version }
    return false
}

@Suite("Update record reconciled with the installed app", .serialized, .timeLimit(.minutes(2)))
struct UpdateRecoveryReconcileTests {
    /// Before its cluster service starts, the supervisor reconciles the record with the installed app: 0.10.7 is the
    /// installed release, the pending 0.10.6 is dropped without a start counted against it, and the rollback copy is
    /// removed, so nothing is rolled back until the next update keeps a copy of 0.10.7.
    @Test func reinstalledMacIsReconciledBeforeItsServiceStarts() throws {
        let mac = try InstalledMac.reinstalledOverAStaleRecord()
        defer { mac.cleanUp() }
        let updater = mac.updater(running: "0.10.7")
        let recovery = ClusterCandidateRecovery(updater: updater), lines = LogLines()

        #expect(recovery.noteLaunch(now: 1_793_749_383, log: { lines.append($0) }) == .notCandidate,
                "the service that starts runs 0.10.7, not the pending 0.10.6")
        #expect(lines.all == ["v0.10.7 is installed, but the update record said v0.9.22 with v0.10.6 pending (installed "
            + "outside the updater): it now records v0.10.7, v0.10.6 is no longer pending and the rollback copy (recorded "
            + "as v0.9.22) is removed; nothing is rolled back until an update keeps a copy of v0.10.7"])

        let state = try mac.store.loadState()
        let installed = try InstalledMac.record(of: mac.app, version: "0.10.7", generation: 3)
        #expect(state.current?.version == "0.10.7")
        #expect(state.current?.binaryHash == installed.binaryHash && state.current?.installedBundleHash == installed.installedBundleHash)
        #expect(state.current?.installGeneration == 3 && state.installGeneration == 3)
        #expect(state.candidate == nil)
        #expect(state.predecessor == nil, "rollback is off until a copy of the installed release exists")
        #expect(!FileManager.default.fileExists(atPath: mac.rollbackCopy.path))
        #expect(throws: SelfUpdater.RollbackRefusal.noPredecessor) { try updater.rollbackPlan() }
        #expect(try mac.installedBinary() == "0.10.7-darkbloom")

        // Reconciled once: the next start finds the record matching, changes nothing and says nothing.
        #expect(recovery.noteLaunch(now: 1_793_749_443, log: { lines.append($0) }) == .notCandidate)
        #expect(lines.all.count == 1)
        #expect(try mac.store.loadState() == state)
    }

    /// A reconcile that died after the record stopped naming the copy, before the copy was gone (the copy's manifest
    /// then names it again) and before the installed app was recorded: the next start finishes it.
    @Test func reconcileThatDiedPartWayIsFinishedAtTheNextStart() throws {
        let mac = try InstalledMac.reinstalledOverAStaleRecord()
        defer { mac.cleanUp() }
        var died = try mac.store.loadState()
        died.candidate = nil
        died.predecessor = nil
        try mac.store.writeState(died)
        let orphan = mac.installRoot.appendingPathComponent("recovery/\(UpdateRecoveryStore.retiredPredecessorPrefix)earlier")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        #expect(try mac.store.loadState().predecessor?.release.version == "0.9.22", "the copy's manifest names it again")

        let lines = LogLines()
        #expect(ClusterCandidateRecovery(updater: mac.updater(running: "0.10.7")).noteLaunch(now: 1_793_749_383,
                                                                                          log: { lines.append($0) }) == .notCandidate)

        let state = try mac.store.loadState()
        #expect(state.current?.version == "0.10.7" && state.candidate == nil && state.predecessor == nil)
        #expect(!FileManager.default.fileExists(atPath: mac.rollbackCopy.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "an earlier removal's leftover is cleaned up")
        #expect(lines.all.count == 1 && lines.all[0].hasPrefix("v0.10.7 is installed, but the update record said v0.9.22 ("))
    }

    /// The update slot on that Mac, before anything reconciled it: the coordinator's latest release is the one it runs,
    /// so it is up to date. Nothing is downloaded, staged, installed or restarted (it said `v0.10.7 -> v0.10.7`).
    @Test func latestReleaseThatRunsIsUpToDateAtTheUpdateSlot() async throws {
        let mac = try InstalledMac.reinstalledOverAStaleRecord()
        defer { mac.cleanUp() }
        let updater = mac.updater(running: "0.10.7", latest: "0.10.7")
        let checked = await updater.checkForUpdate()
        #expect(isUpToDate(checked, at: "0.10.7"), "\(checked)")

        let log = LogLines(), restarts = LogLines()
        let progressPath = mac.root.appendingPathComponent("service-update.json")
        let otherMac = ClusterPairUpdateProgress(phase: .idle, running: "0.10.7", writtenAt: Date().timeIntervalSince1970)
        let cycle = ClusterPairUpdateCycle(environment: .init(updater: updater, progressPath: progressPath,
            partner: { .reported(otherMac) }, part: { .notRunning }, partStarting: { _ in false },
            mailboxDirectory: mac.root.appendingPathComponent("lifecycle", isDirectory: true), pairRunsHere: { true },
            log: { log.append($0) }))
        let outcome = await cycle.run { restarts.append($0) }

        #expect(outcome == .upToDate, "\(log.all)")
        #expect(restarts.all.isEmpty)
        #expect(!log.all.contains { $0.contains("v0.10.7 -> v0.10.7") }, "\(log.all)")
        #expect(log.all.contains("cluster update: up to date (v0.10.7)"), "\(log.all)")
        #expect(ClusterPairUpdate.readProgress(from: progressPath)?.detail == "up to date")
        #expect(mac.stagingDirectories().isEmpty)
        #expect(try mac.installedBinary() == "0.10.7-darkbloom")
    }

    /// Three ends of the cluster service on that Mac, each after the start the supervisor notes: none is charged to
    /// the stale 0.10.6, so the 0.10.2 app in the rollback copy never replaces 0.10.7 (a 0.10.2/0.10.7 pair never forms).
    @Test func threeEndsOfTheServiceNeverRestoreTheStaleRollbackCopy() throws {
        let mac = try InstalledMac.reinstalledOverAStaleRecord()
        defer { mac.cleanUp() }
        let recovery = ClusterCandidateRecovery(updater: mac.updater(running: "0.10.7"))

        var ends: [ClusterCandidateRecovery.Failure] = []
        for start in 0..<3 {
            let now = 1_793_749_383 + Double(start) * 60
            _ = recovery.noteLaunch(now: now)
            ends.append(recovery.recordFailedStart(now: now + 5))
        }

        #expect(ends == [.notCandidate, .notCandidate, .notCandidate])
        #expect(try mac.installedBinary() == "0.10.7-darkbloom")
        let state = try mac.store.loadState()
        #expect(state.current?.version == "0.10.7" && state.quarantine == nil)
    }

    /// An installed, recorded candidate whose rollback copy is not the release it is recorded as (its app is signed as
    /// 0.10.2, recorded as 0.9.22): three failed starts keep the candidate, and the copy is never restored.
    /// The validator's case: an earlier updater on a Mac reinstalled with `install.sh` kept a copy of 0.10.7 but recorded
    /// it as 0.10.6 (its stale record's label), then installed 0.10.8. The copy is the release this Mac ran before 0.10.8,
    /// so it is recorded as 0.10.7 and kept: three failed starts restore it, as on the other Mac, which keeps 0.10.7.
    @Test func rollbackCopyRecordedAsAnotherReleaseIsRelabelledAndRestored() throws {
        let mac = try InstalledMac.updatedOverAMislabelledCopy()
        defer { mac.cleanUp() }
        let recorded = try #require(try mac.store.loadState().predecessor)
        let recovery = ClusterCandidateRecovery(updater: mac.updater(running: "0.10.8")), lines = LogLines()

        var ends: [ClusterCandidateRecovery.Failure] = []
        for start in 0..<3 {
            let now = 1_793_000_000 + Double(start) * 60
            #expect(recovery.noteLaunch(now: now, log: { lines.append($0) }) == .candidate(version: "0.10.8", failedStarts: start))
            if start == 0 {
                let kept = try mac.store.loadState().predecessor
                #expect(kept?.release.version == "0.10.7")
                #expect(kept?.release.installedBundleHash == recorded.release.installedBundleHash
                        && kept?.release.binaryHash == recorded.release.binaryHash, "its verified files are kept")
                let manifest = try? JSONDecoder().decode(VerifiedPredecessor.self, from: Data(contentsOf:
                    mac.rollbackCopy.appendingPathComponent("manifest.json")))
                #expect(manifest?.release.version == "0.10.7", "the manifest inside the copy says so too")
            }
            ends.append(recovery.recordFailedStart(now: now + 5, log: { lines.append($0) }))
        }

        #expect(lines.all == ["the rollback copy recorded as v0.10.6 is a v0.10.7 app: it is now recorded as v0.10.7 and "
            + "kept for rollback"])
        #expect(ends == [.counted(version: "0.10.8", failures: 1), .counted(version: "0.10.8", failures: 2),
                         .rolledBack(from: "0.10.8", to: "0.10.7")])
        #expect(try mac.installedBinary() == "0.10.7-darkbloom")
        let state = try mac.store.loadState()
        #expect(state.current?.version == "0.10.7" && state.candidate == nil && state.quarantine?.version == "0.10.8")
    }

    /// A copy whose release cannot be verified is still removed (fail closed): its app names no version while the
    /// installed app does, or its files are not the ones recorded for it. Three failed starts then keep the candidate.
    @Test(arguments: ["names no version", "changed files"])
    func rollbackCopyThatCannotBeVerifiedIsRemoved(fault: String) throws {
        let mac = try InstalledMac.updatedOverAMislabelledCopy(copyNamesVersion: fault != "names no version")
        defer { mac.cleanUp() }
        if fault == "changed files" {
            try Data("0.10.7-darkbloom, changed".utf8)
                .write(to: mac.rollbackCopy.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom"))
        }
        let recovery = ClusterCandidateRecovery(updater: mac.updater(running: "0.10.8")), lines = LogLines()

        var ends: [ClusterCandidateRecovery.Failure] = []
        for start in 0..<3 {
            let now = 1_793_000_000 + Double(start) * 60
            #expect(recovery.noteLaunch(now: now, log: { lines.append($0) }) == .candidate(version: "0.10.8", failedStarts: start))
            ends.append(recovery.recordFailedStart(now: now + 5, log: { lines.append($0) }))
        }

        #expect(lines.all == ["the rollback copy recorded as v0.10.6 could not be verified as the release its app is "
            + "signed as, so it is removed; nothing is rolled back until an update keeps a copy of the installed release"])
        #expect(Array(ends.prefix(2)) == [.counted(version: "0.10.8", failures: 1), .counted(version: "0.10.8", failures: 2)])
        guard case .rollbackRefused("0.10.8", _) = ends.last else {
            Issue.record("the unverified copy was restored: \(ends)")
            return
        }
        #expect(try mac.installedBinary() == "0.10.8-darkbloom")
        #expect(!FileManager.default.fileExists(atPath: mac.rollbackCopy.path))
        #expect(try mac.store.loadState().quarantine == nil)
    }

    /// A damaged install (its `mlx.metallib` is gone) is no evidence that another app was installed: the record stays,
    /// the failed starts count, and the third restores the verified copy, as 0.10.7 did.
    @Test func damagedInstalledAppStillRollsBackToTheVerifiedCopy() throws {
        let mac = try InstalledMac(installed: "0.10.8")
        defer { mac.cleanUp() }
        let copy = try mac.keepRollbackCopy(signed: "0.10.7", recordedAs: "0.10.7", generation: 1)
        let pending = PendingReleaseCandidate(release: try InstalledMac.record(of: mac.app, version: "0.10.8", generation: 2),
                                              failureCount: 0)
        try mac.store.writeState(UpdateRecoveryState(installGeneration: 2, current: copy.release, candidate: pending,
                                                     predecessor: copy))
        try FileManager.default.removeItem(at: mac.app.appendingPathComponent("Contents/MacOS/mlx.metallib"))
        let recovery = ClusterCandidateRecovery(updater: mac.updater(running: "0.10.8")), lines = LogLines()

        var ends: [ClusterCandidateRecovery.Failure] = []
        for start in 0..<3 {
            let now = 1_793_000_000 + Double(start) * 60
            #expect(recovery.noteLaunch(now: now, log: { lines.append($0) }) == .candidate(version: "0.10.8", failedStarts: start))
            ends.append(recovery.recordFailedStart(now: now + 5, log: { lines.append($0) }))
        }

        #expect(ends == [.counted(version: "0.10.8", failures: 1), .counted(version: "0.10.8", failures: 2),
                         .rolledBack(from: "0.10.8", to: "0.10.7")])
        #expect(try mac.installedBinary() == "0.10.7-darkbloom")
        #expect(FileManager.default.fileExists(atPath: mac.app.appendingPathComponent("Contents/MacOS/mlx.metallib").path))
        #expect(lines.all.isEmpty, "\(lines.all)")
        #expect(try mac.store.loadState().quarantine?.version == "0.10.8")
    }

    /// How the M5 Max's copy came to be recorded as 0.9.22: the updater installed 0.10.6 over a 0.10.2 app that the
    /// installer had put in place while the record still said 0.9.22. The copy is recorded as the release its app is
    /// signed as, and that release as the installed one it replaced.
    @Test func updateOverAnInstallMadeOutsideTheUpdaterRecordsTheCopyAsTheReleaseItIs() throws {
        let mac = try InstalledMac(installed: "0.10.2")
        defer { mac.cleanUp() }
        try mac.store.writeState(UpdateRecoveryState(installGeneration: 1,
                                                     current: try mac.record(ofReleaseNotOnDisk: "0.9.22", generation: 1)))
        let release = try mac.release("0.10.6")
        let updater = mac.updater(running: "0.10.2")

        guard case .success = updater.installBundleForTesting(from: release.tarball, release: release.info, installDir: mac.installRoot)
        else { Issue.record("0.10.6 was not installed"); return }

        let state = try mac.store.loadState()
        #expect(state.candidate?.release.version == "0.10.6")
        #expect(state.predecessor?.release.version == "0.10.2", "the copy is the 0.10.2 app")
        #expect(state.current?.version == "0.10.2", "and 0.10.2 is the release it replaced")
        #expect(try mac.installedBinary() == "0.10.6-darkbloom")
    }

    /// The updater installing a release over that stale record (`darkbloom update` before the cluster service started
    /// again): the copy it keeps is of the installed 0.10.7, not the stale copy a pending 0.10.6 that is not installed
    /// would hand on to the new release.
    @Test func updateOverAStaleRecordKeepsACopyOfTheInstalledApp() throws {
        let mac = try InstalledMac.reinstalledOverAStaleRecord()
        defer { mac.cleanUp() }
        let release = try mac.release("0.10.8")

        guard case .success = mac.updater(running: "0.10.7").installBundleForTesting(
            from: release.tarball, release: release.info, installDir: mac.installRoot)
        else { Issue.record("0.10.8 was not installed"); return }

        let state = try mac.store.loadState()
        #expect(state.candidate?.release.version == "0.10.8")
        #expect(state.predecessor?.release.version == "0.10.7", "the copy is of the installed 0.10.7")
        #expect(try mac.installedBinary() == "0.10.8-darkbloom")
        let copy = mac.rollbackCopy.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "0.10.7-darkbloom")
        #expect(state.current?.version == "0.10.7" && state.quarantine == nil)
    }

    /// The normal path with apps that name their version is unchanged: the updater installs 2.0.0 over 1.0.0 and keeps
    /// a copy of 1.0.0; 2.0.0 is the candidate at every start; a healthy service promotes it and the copy is kept; three
    /// failed starts restore 1.0.0 and quarantine 2.0.0. A newer release is offered; the running one is not.
    @Test(arguments: [true, false])
    func normalUpdatePromotionAndRollbackAreUnchanged(healthy: Bool) async throws {
        let mac = try InstalledMac(installed: "1.0.0")
        defer { mac.cleanUp() }
        let release = try mac.release("2.0.0")
        let installing = mac.updater(running: "1.0.0", latest: "2.0.0")
        guard case .success = installing.installBundleForTesting(from: release.tarball, release: release.info, installDir: mac.installRoot)
        else { Issue.record("2.0.0 was not installed"); return }
        guard case .restartRequired("1.0.0", "2.0.0") = await installing.checkForUpdate() else {
            Issue.record("the installed candidate is not restarted into"); return
        }
        try installing.prepareCandidateLaunch(operation: "test-cluster-restart", baseline: nil)

        // The supervisor started again from 2.0.0.
        let running = mac.updater(running: "2.0.0", latest: "2.0.0")
        let recovery = ClusterCandidateRecovery(updater: running, stabilizationSeconds: 10)
        #expect(recovery.noteLaunch(now: 1_000) == .candidate(version: "2.0.0", failedStarts: 0))
        #expect(try mac.store.loadState().predecessor?.release.version == "1.0.0")

        if healthy {
            #expect(recovery.observe(healthy: true, processStartedAt: 999, now: 1_001) == .stabilizing)
            #expect(recovery.observe(healthy: true, processStartedAt: 999, now: 1_011) == .promoted(version: "2.0.0"))
            #expect(recovery.noteLaunch(now: 1_020) == .notCandidate)
            let state = try mac.store.loadState()
            #expect(state.current?.version == "2.0.0" && state.candidate == nil)
            #expect(state.predecessor?.release.version == "1.0.0", "the copy of 1.0.0 is kept for rollback")
            #expect(isUpToDate(await running.checkForUpdate(), at: "2.0.0"))
            guard case .updateAvailable(let current, let latest) = await mac.updater(running: "2.0.0", latest: "3.0.0").checkForUpdate()
            else { Issue.record("3.0.0 is not offered"); return }
            #expect(current == "2.0.0" && latest.version == "3.0.0")
        } else {
            #expect(recovery.recordFailedStart(now: 1_005) == .counted(version: "2.0.0", failures: 1))
            #expect(recovery.noteLaunch(now: 1_100) == .candidate(version: "2.0.0", failedStarts: 1))
            #expect(recovery.recordFailedStart(now: 1_105) == .counted(version: "2.0.0", failures: 2))
            #expect(recovery.noteLaunch(now: 1_200) == .candidate(version: "2.0.0", failedStarts: 2))
            #expect(recovery.recordFailedStart(now: 1_205) == .rolledBack(from: "2.0.0", to: "1.0.0"))
            #expect(try mac.installedBinary() == "1.0.0-darkbloom")
            let state = try mac.store.loadState()
            #expect(state.current?.version == "1.0.0" && state.candidate == nil && state.quarantine?.version == "2.0.0")
            #expect(recovery.noteLaunch(now: 1_300) == .notCandidate, "the restored release starts as an ordinary start")
            #expect(try mac.store.loadState() == state, "the restored release is what the record says")
        }
    }
}
