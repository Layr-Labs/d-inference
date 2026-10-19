import Darwin
import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@_spi(OwnerService) import DarkbloomClusterRemote
@testable import ProviderCore

/// UNRUN. Parent owns actual compilation/execution. Uses real locks and actual
/// schema-emitting CPU children only. No model/GPU/cable/native-payload claim.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_INPUT"] != nil
    || ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationInstalledOwnerTests {
    typealias O = GLM5NextCalibrationInstalledOwner
    typealias F = GLM5NextCalibrationInstalledOwnerFixture

    @Test func prepareOwnsBothRealGatesAndCancellationProvesNoLaunch() throws {
        let f = try F(); defer { f.cleanup() }
        #expect(f.local.status().phase == .prepared)
        #expect(throws: (any Error).self) { try UpdateProcessLock.acquire(at: f.providerLock, operation: "ordinary-provider") }
        #expect(throws: (any Error).self) { try ClusterDeviceLease(directoryURL: f.seed.base.device) }
        let publicDocument = try JSONSerialization.jsonObject(with: f.local.outboundDocument) as! [String: Any]
        #expect(Set(publicDocument.keys) == ["payload", "signature"])
        #expect(throws: (any Error).self) {
            try f.local.launch(requireBothAuthenticatedCommits: { _, _, _ in Issue.record("Must not reach callback without commits") },
                publish: { _, _, _ in Issue.record("No child was launched") })
        }
        let documents = f.seed.base.device.appendingPathComponent("glm-calibration")
        #expect(try FileManager.default.contentsOfDirectory(atPath: documents.path).count == 1)
        f.local.cancel()
        #expect(try FileManager.default.contentsOfDirectory(atPath: documents.path).isEmpty)
        #expect(f.local.status().phase == .retired)
        #expect(f.local.status().journalResolved)
        #expect(f.local.actualExit() == nil)
        #expect(!FileManager.default.fileExists(atPath: f.marker("starts").path))
        let provider = try UpdateProcessLock.acquire(at: f.providerLock, operation: "fresh-contender")
        let device = try ClusterDeviceLease(directoryURL: f.seed.base.device)
        withExtendedLifetime((provider, device)) {}
    }

    @Test func exactNativeUUIDsCommitOnceAndRequiredPeerConfirmationCanRefuse() throws {
        let f = try F(); defer { f.cleanup() }
        let committed = try f.commit()
        #expect(committed.starts.map(\.rank) == [0, 1])
        #expect(committed.localStart.ownerIncarnation == committed.binding.route.ownerIncarnation)
        #expect(committed.localStart.leaseID == committed.binding.route.leaseID)
        #expect(committed.localStart.common.epoch == committed.binding.route.membershipEpoch)
        #expect(throws: (any Error).self) { try f.local.commit(peerStart: committed.starts[1 - f.rank]) }
        #expect(throws: (any Error).self) { try f.local.admit(peerDocument: f.peer.outboundDocument) }
        let expectedPairRecord = f.localQuote.pair.record
        let expectedDeadline = f.local.experimentDeadline
        try f.local.launch(requireBothAuthenticatedCommits: { pair, context, deadline in
            #expect(pair.record == expectedPairRecord)
            #expect(context.starts.map(\.canonicalBytes) == committed.starts.map(\.canonicalBytes))
            #expect(deadline == expectedDeadline)
            // Deliberate trusted-adapter refusal; never a fake successful channel.
            throw ClusterConfigurationError.invalid("Fixture peer has not confirmed both commits")
        }, publish: { _, _, _ in Issue.record("Refused peer confirmation must not publish") })
        #expect(throws: (any Error).self) {
            try f.local.launch(requireBothAuthenticatedCommits: { _, _, _ in }, publish: { _, _, _ in })
        }
        try f.wait { f.local.status().phase == .retired }
        #expect(!FileManager.default.fileExists(atPath: f.marker("starts").path))
        #expect(f.local.actualExit() == nil)
        #expect(f.local.status().launchCheckpoint == .peerCommits)
        #expect(throws: (any Error).self) { try f.local.completed() }
    }

    @Test(arguments: ["worker", "config", "matrix", "pair"])
    func changedRetainedInputRefusesWithoutSpawnAndResolvesOnlyNoLaunch(input: String) throws {
        let f = try F(); defer { f.cleanup() }
        _ = try f.commit()
        let worker = f.seed.base.worker
        let configuration = f.seed.base.model.appendingPathComponent("config.json")
        let matrix = f.matrix
        let pairing = f.seed.base.pairing
        let pairRecords = pairing.store.recordsFile
        // Prepare the same valid replacement records as Fixture.write(), then
        // transfer immutable bytes rather than the mutable fixture to the queue.
        var records = try JSONSerialization.jsonObject(with: Data(contentsOf: pairRecords)) as! [String: Any]
        records["pairings"] = [try pairing.record(pairing.peer, timestamp: "2026-10-01T00:00:00Z"),
            try pairing.record(pairing.newer, timestamp: "2026-10-02T00:00:00Z")]
        let replacementPairRecords = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        try f.local.launch(requireBothAuthenticatedCommits: { _, _, _ in
            // Boundary after the trusted transport affirmation must still
            // inspect actual own files/pair/matrix before recording/spawning.
            switch input {
            case "worker": try Data("changed CPU helper".utf8).write(to: worker)
            case "config": try Data("changed config".utf8).write(to: configuration)
            case "matrix": try Data("[[null,\"rdma_en9\"],[\"rdma_en9\",null]]".utf8).write(to: matrix)
            default: try replacementPairRecords.write(to: pairRecords)
            }
        }, publish: { _, _, _ in Issue.record("Changed selection must not bootstrap") })
        try f.wait { f.local.status().phase == .retired }
        #expect(!FileManager.default.fileExists(atPath: f.marker("starts").path))
        #expect(f.local.actualExit() == nil)
        #expect(f.local.status().failure == "launch-refused")
        #expect(f.local.status().launchCheckpoint == .currentBeforeSetup)
        #expect(try Data(contentsOf: f.seed.base.device.appendingPathComponent("native-device.lease")).isEmpty)
    }

    @Test func realReportBeforeExitAndCancelRetainActualGatesUntilDirectChildExit() throws {
        let f = try F(); defer { f.cleanup() }
        let expected = try f.commit()
        try f.local.launch(requireBothAuthenticatedCommits: { _, actual, _ in
            // Fixture-only in-memory observation of BOTH genuine local commits.
            #expect(actual.starts.map(\.canonicalBytes) == expected.starts.map(\.canonicalBytes))
        }, publish: { _, _, _ in Issue.record("Python fixture must not fabricate a native prelude") })
        try f.wait { f.local.status().provisionalReportReceived }
        #expect(!f.local.status().observedExit)
        #expect(f.local.actualExit() == nil)
        #expect(throws: (any Error).self) { try f.local.completed() }
        try f.requireLocksHeld()
        f.local.cancel()
        try f.requireLocksHeld()
        #expect(f.local.actualExit() == nil)
        try f.release(code: 9)
        try f.wait { f.local.actualExit() != nil }
        #expect(f.local.actualExit()?.termination == .exited(9))
        #expect(f.local.actualExit()?.localJournalResolved == true)
        #expect(throws: (any Error).self) { try f.local.completed() }
        let provider = try UpdateProcessLock.acquire(at: f.providerLock, operation: "after-actual-exit")
        let device = try ClusterDeviceLease(directoryURL: f.seed.base.device)
        withExtendedLifetime((provider, device)) {}
    }

    @Test func callerDropAndObservationTimeoutKeepRealLocksAndJournal() throws {
        // This one regression must rely on production O self-retention: the
        // fixture custody task keeps seed/peer but holds local only weakly.
        let f = try F(localCustody: .observerOnly); defer { f.cleanup() }
        let expected = try f.commit()
        var owner: O? = f.local
        f.droppedOwner = owner
        weak var weakOwner = owner
        defer { weakOwner = nil }
        try #require(owner).launch(requireBothAuthenticatedCommits: { _, actual, _ in
            #expect(actual.starts.map(\.canonicalBytes) == expected.starts.map(\.canonicalBytes))
        }, publish: { _, _, _ in Issue.record("No fake native bootstrap") })
        try f.wait { weakOwner?.status().provisionalReportReceived == true }
        // A serial adapter poll may time out here. Neither timeout nor caller
        // dropping every strong reference grants permission to clear ownership.
        f.local = nil; owner = nil
        usleep(50_000)
        #expect(weakOwner != nil)
        #expect(f.cleanupObservationFailure() == nil)
        #expect(weakOwner?.actualExit() == nil)
        try f.requireLocksHeld()
        try f.release()
        try f.wait { weakOwner?.actualExit() != nil }
        #expect(weakOwner?.actualExit()?.termination == .exited(0))
        #expect(weakOwner?.status().journalResolved == true)
        // Cache real observed exit/local retirement before listener cancellation
        // can remove production's final strong reference. No synthetic success.
        try f.requireLocalRetirementEvidence()
        #expect(f.cleanupObservationFailure() == nil)
        #expect(throws: (any Error).self) { try #require(weakOwner).completed() } // Bootstrap never completed.
        weakOwner?.cancel() // Closes the intentionally unfinished fixture listener.
        let provider = try UpdateProcessLock.acquire(at: f.providerLock, operation: "after-observed-exit")
        let device = try ClusterDeviceLease(directoryURL: f.seed.base.device)
        withExtendedLifetime((provider, device)) {}
    }

    @Test(arguments: ["provider", "device"])
    func canonicalProviderAndDeviceReplacementInvalidateHeldChecks(gate: String) throws {
        let f = try F(); defer { f.cleanup() }
        let path = gate == "provider" ? f.providerLock : f.seed.base.device.appendingPathComponent("native-device.lease")
        let old = path.appendingPathExtension("old")
        try FileManager.default.moveItem(at: path, to: old)
        try Data("replacement".utf8).write(to: path)
        #expect(throws: (any Error).self) { try f.local.admit(peerDocument: f.peer.outboundDocument) }
        // Restore the same canonical inode before no-launch cleanup. No
        // overwritten lock or sticky journal is silently recovered by this test.
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: old, to: path)
        f.local.cancel()
        #expect(f.local.status().phase == .retired)
    }
    @Test func actualJournalPrecedesAnySpawnAndTamperingCannotResolveIt() throws {
        let f = try F(); defer { f.cleanup() }
        let context = try f.commit()
        let directory = f.root.appendingPathComponent("journal-negative-device")
        let providerPath = f.root.appendingPathComponent("journal-negative-provider.pid.lock")
        let environment = O.Resources.Environment.isolatedTests(providerLock: providerPath,
            deviceDirectory: directory, orphanCheck: {}, linkReady: { _ in },
            requirePhysicalInterface: { _, _ in })
        let resources = try O.Resources(environment: environment,
            deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        try resources.record(binding: context.binding, launchID: context.localStart.launchID)
        let journal = directory.appendingPathComponent("native-device.lease")
        let original = try Data(contentsOf: journal)
        let object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        #expect(object["nativeLaunchID"] as? String == context.localStart.launchID.uuidString.lowercased())
        #expect(object["ownerIncarnation"] as? String == context.binding.route.ownerIncarnation.uuidString.lowercased())
        #expect(object["leaseID"] as? String == context.binding.route.leaseID.uuidString.lowercased())
        try Data("changed journal".utf8).write(to: journal)
        #expect(throws: (any Error).self) { try resources.requireHeld() }
        #expect(throws: (any Error).self) { try resources.retireAfterExitOrNoLaunch() }
        #expect(!resources.retired)
        #expect(throws: (any Error).self) { try UpdateProcessLock.acquire(at: providerPath, operation: "contender") }
        #expect(throws: (any Error).self) { try ClusterDeviceLease(directoryURL: directory) }
        // Test itself proves no spawn and restores only its exact own bytes;
        // production has no auto-repair or journal-recovery path here.
        try original.write(to: journal)
        try resources.retireAfterExitOrNoLaunch()
        #expect(resources.retired)
        #expect(try Data(contentsOf: journal).isEmpty)
    }

    @Test func unsafeProviderLockFilesRefuseBeforeWritingOwnerMetadata() throws {
        let f = try F(); defer { f.cleanup() }
        let target = f.root.appendingPathComponent("untouched-target")
        let original = Data("fixture public bytes".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = f.root.appendingPathComponent("unsafe-symbolic-lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try UpdateProcessLock.acquire(at: link, operation: "refused") }
        #expect(try Data(contentsOf: target) == original)
        let hard = f.root.appendingPathComponent("unsafe-hard-lock")
        try FileManager.default.linkItem(at: target, to: hard)
        #expect(throws: (any Error).self) { try UpdateProcessLock.acquire(at: hard, operation: "refused") }
        #expect(try Data(contentsOf: target) == original)
        let fifo = f.root.appendingPathComponent("unsafe-fifo-lock")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try UpdateProcessLock.acquire(at: fifo, operation: "refused") }
    }

    /// UNRUN: two genuine supervised CPU children; no native bootstrap/model.
    /// Cleanup timeout must preserve the base destructor's entire scratch until
    /// BOTH actual child exits and local journal retirements have been observed.
    @Test func cleanupTimeoutAndFixtureDropRetainBaseUntilBothActualChildrenRetire() throws {
        var fixture: F? = try F()
        let local = try #require(fixture?.local)
        let peer = try #require(fixture?.peer)
        let expected = try #require(fixture).commit()
        let model = try #require(fixture).seed.base.model
        let root = try #require(fixture).root
        let proof = model.appendingPathComponent("cleanup-file-proof")
        let holds = (0...1).map { model.appendingPathComponent("finite-hold-" + String($0)) }
        let releases = (0...1).map { model.appendingPathComponent("finite-release-" + String($0)) }
        let journals = [try #require(fixture).seed.base.device,
                        try #require(fixture).seed.peerDevice].map { $0.appendingPathComponent("native-device.lease") }
        weak var base = try #require(fixture).seed.base
        defer {
            for path in holds { try? FileManager.default.removeItem(at: path) }
            for path in releases { try? Data("0".utf8).write(to: path) }
            local.cancel(); peer.cancel()
            fixture?.cleanup()
            base = nil
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            while !condition(), DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
            try #require(condition())
        }
        try Data("retained until both actual retirements".utf8).write(to: proof)
        for path in holds { try Data("hold actual child exit".utf8).write(to: path) }
        for owner in [local, peer] {
            try owner.launch(requireBothAuthenticatedCommits: { _, context, _ in
                // In-memory fixture-only confirmation of both genuine commits;
                // never claimed as authenticated service-control qualification.
                #expect(context.starts.map(\.canonicalBytes) == expected.starts.map(\.canonicalBytes))
            }, publish: { _, _, _ in Issue.record("CPU fixture cannot fabricate native bootstrap") })
        }
        try wait { local.status().provisionalReportReceived && peer.status().provisionalReportReceived }
        #expect(throws: F.CleanupError.unresolvedRanks([0, 1])) {
            try #require(fixture).cleanup(joinTimeout: 0.02)
        }
        fixture = nil // No fixture caller remains to own seed/base/scratch.
        usleep(100_000)
        #expect(base != nil)
        #expect(FileManager.default.fileExists(atPath: proof.path))
        #expect(local.actualExit() == nil && peer.actualExit() == nil)
        for path in journals { #expect(try !Data(contentsOf: path).isEmpty) }

        // Cleanup has already written BOTH release markers. Removing just one
        // hold must not let the base destructor remove the other child's proof.
        try FileManager.default.removeItem(at: holds[local.status().rank])
        try wait { local.actualExit()?.localJournalResolved == true }
        #expect(local.actualExit()?.termination == .exited(0))
        #expect(peer.actualExit() == nil)
        usleep(100_000)
        #expect(base != nil)
        #expect(FileManager.default.fileExists(atPath: proof.path))
        #expect(try !Data(contentsOf: journals[1]).isEmpty)

        try FileManager.default.removeItem(at: holds[peer.status().rank])
        try wait { peer.actualExit()?.localJournalResolved == true }
        #expect(peer.actualExit()?.termination == .exited(0))
        // Weak references clear before deinit finishes removing scratch.
        // Join both terminal facts within the existing three-second bound.
        try wait { base == nil && !FileManager.default.fileExists(atPath: root.path) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func droppingFixtureWithoutCleanupRetainsBaseUntilBothProvenNoLaunchRetirements() throws {
        var fixture: F? = try F()
        let local = try #require(fixture?.local)
        let peer = try #require(fixture?.peer)
        let root = try #require(fixture).root
        weak var base = try #require(fixture).seed.base
        defer {
            local.cancel(); peer.cancel()
            fixture?.cleanup()
            base = nil
        }
        fixture = nil
        #expect(base != nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
        local.cancel()
        #expect(local.status().journalResolved)
        #expect(local.actualExit() == nil)
        usleep(100_000)
        #expect(base != nil) // Other owner is still holding its actual scope.
        peer.cancel()
        #expect(peer.status().journalResolved)
        #expect(peer.actualExit() == nil)
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        // Weak disappearance alone does not join the scratch destructor.
        while (base != nil || FileManager.default.fileExists(atPath: root.path)),
              DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
        #expect(base == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

}
