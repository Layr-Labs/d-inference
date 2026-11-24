import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

/// The leader's step that saves a fetched cluster approval on both Macs (`ClusterApprovalSync`), with each Mac's real
/// configuration store, pairing store and installed files, the coordinator a real local HTTP server, and the follower's
/// side its cluster service's own handling of the `approval` command.
@Suite("Cluster approval sync", .serialized)
struct ClusterApprovalSyncTests {
    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func attachment(_ macs: ClusterApprovalMacs, _ mac: ClusterApprovalMacs.Mac) throws -> ClusterNativeMemberAttachment? {
        try macs.saved(mac).configuration.nativeMember
    }

    @Test func anOfferedEntryIsSavedOnBothRanksFromEachMacsOwnFiles() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        macs.recordLinkProbe()
        let serial = macs.approval(schedule: 1)
        mock.setClusterApprovals(body: try ClusterApprovalMacs.body([macs.approval(schedule: 2), serial,
                                                                     macs.approval(model: "other/model")]))
        let fetched = await ClusterApprovalFetch.fetch(coordinatorURL: url)
        let sent = ClusterApprovalRecorder<ClusterServiceCommand>(), facts = try macs.facts()
        let result = macs.sync(fetched, leaderFacts: facts, followerFacts: facts, sent: sent)
        #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(serial), note: .some(nil)))
        #expect(sent.values.map(\.op) == [.approval] && sent.values.first?.approval == serial)

        let roster = ClusterPairingRosterCheck.roster(of: try #require(try macs.leader.pairing.load()?.pairings.first))
        for mac in macs.macs {
            let saved = try #require(try attachment(macs, mac), "rank \(mac.rank) saved no approval")
            let other = macs.macs[1 - mac.rank]
            #expect(saved.schema == ClusterNativeMemberAttachment.rosterSchemaName && saved.clusterApproval == serial)
            #expect(saved.roster == roster && saved.memberPins == [macs.leader.pin, macs.follower.pin])
            #expect(saved.ownerSHA256 == (try sha256(mac.owner)))
            let helpers = mac.worker.deletingLastPathComponent()
            #expect(saved.metallibPath == helpers.appendingPathComponent("mlx.metallib").path)
            #expect(saved.resourceLibraryPath == helpers.appendingPathComponent("pagedattention.metal").path)
            // The leader's measured link: 4 MiB in 400 us is 83,886 Mbit/s, two 20 us one-way records one round trip.
            #expect(saved.edges == [ClusterEdge(peerPin: other.pin, transport: "rdma", measuredMbps: 83_886, measuredRTTMicros: 40)])
            #expect(try saved.policyBytes == serial.canonicalPolicy())
        }
        // Asked again with the same answer: nothing is written and nothing is sent.
        let before = try macs.macs.map(macs.bytes)
        #expect(macs.sync(fetched, leaderFacts: facts, followerFacts: facts, sent: sent) == .unchanged)
        #expect(try macs.macs.map(macs.bytes) == before && sent.values.count == 1)
        await mock.shutdown()
    }

    @Test func aCoordinatorWithoutPairingLeavesBothSetupsByteForByte() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        let before = try macs.macs.map(macs.bytes)
        let fetched = await ClusterApprovalFetch.fetch(coordinatorURL: url)
        #expect(fetched == .notOffered)
        let sent = ClusterApprovalRecorder<ClusterServiceCommand>(), facts = try macs.facts()
        #expect(macs.sync(fetched, leaderFacts: facts, followerFacts: facts, sent: sent) == .unchanged)
        #expect(try macs.macs.map(macs.bytes) == before && sent.values.isEmpty)
        await mock.shutdown()
    }

    @Test func anEntryWithAnyDigestThatIsNotThisMacsIsSavedOnNeitherMac() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let before = try macs.macs.map(macs.bytes), approval = macs.approval(), facts = try macs.facts()
        for field in ClusterApprovalMacs.blockFields {
            // An entry whose digest is not the leader's own is not this setup's entry: nothing is sent or said.
            let sent = ClusterApprovalRecorder<ClusterServiceCommand>()
            let mine = macs.sync(.approvals([approval]), leaderFacts: try macs.facts(differing: field), followerFacts: facts, sent: sent)
            #expect(mine == .unchanged && sent.values.isEmpty, "\(field)")
            // The follower's own check refuses it: the leader then saves nothing either.
            let theirs = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: try macs.facts(differing: field))
            #expect(!theirs.changed, "\(field)")
            #expect(theirs.line?.contains(ClusterApprovalSync.peerRefusalPrefix + "the approval's \(field) differ") == true, "\(theirs.line ?? "")")
            #expect(try macs.macs.map(macs.bytes) == before, "\(field) left a saved approval")
        }
    }

    /// A build-pinned entry that matches this Mac's installation but not its saved setup (the setup was re-adopted for
    /// another build, as after a rollback and forward): the refusal names each pin that differs with both values, and
    /// the refused approval is kept beside the note for the next comparison.
    @Test func aRefusalNamesEachPinTheSavedSetupDiffersInAndKeepsTheApproval() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts()
        try macs.readopt(runtime: ClusterApprovalMacs.hash("9"))
        let before = try macs.macs.map(macs.bytes), sent = ClusterApprovalRecorder<ClusterServiceCommand>()
        let result = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts, sent: sent)
        let runtime = "runtime (approval \(String(repeating: "a", count: 12)), setup \(String(repeating: "9", count: 12)))"
        #expect(!result.changed && sent.values.isEmpty)
        #expect(result.line?.contains("Saved pair approval differs from this setup in its " + runtime) == true,
                "\(result.line ?? "")")
        #expect(result.note == .some(result.line))
        #expect(result.refused == approval)
        #expect(try macs.macs.map(macs.bytes) == before)
    }

    /// The other Mac recorded a refusal while it led (leadership moves between the Macs). Its own refusal keeps that
    /// note; once it saves the leader's approval, the note no longer says why the pair isn't offered and is cleared.
    @Test func theOtherMacClearsItsRefusalNoteWhenItSavesTheLeadersApproval() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts()
        let record = ClusterSetupStore(paths: .init(paths: macs.follower.paths))
        let stale = "Not offered for pairing: this Mac's check refused it: Saved pair approval differs"
        _ = try record.updateRecord { $0.approvalNote = stale }
        let refused = macs.sync(.approvals([approval]), leaderFacts: facts,
                                followerFacts: try macs.facts(differing: "metallib_sha256"))
        #expect(!refused.changed)
        #expect(try record.readRecord().approvalNote == stale)
        #expect(macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts).changed)
        #expect(try record.readRecord().approvalNote == nil)
    }

    @Test func onlyTheEntryOfThisModelAndPrefillScheduleIsTaken() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let before = try macs.macs.map(macs.bytes), facts = try macs.facts()
        let others = [macs.approval(schedule: 2), macs.approval(model: "other/model")]
        #expect(macs.sync(.approvals(others), leaderFacts: facts, followerFacts: facts) == .unchanged)
        #expect(try macs.macs.map(macs.bytes) == before)
        let serial = macs.approval(schedule: 1)
        #expect(macs.sync(.approvals(others + [serial]), leaderFacts: facts, followerFacts: facts).changed)
        #expect(try attachment(macs, macs.follower)?.clusterApproval == serial)
    }

    @Test func anApprovalNearItsEndIsReplacedAndAnEndedOneIsRemovedOnBothMacs() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let facts = try macs.facts()
        let near = macs.approval(endsIn: 3_600, id: "near"), later = macs.approval(endsIn: 14 * 86_400, id: "later")
        #expect(macs.sync(.approvals([near]), leaderFacts: facts, followerFacts: facts).changed)
        // Within a day of its end and the coordinator has a later one: both Macs take it.
        #expect(macs.sync(.approvals([later]), leaderFacts: facts, followerFacts: facts).changed)
        for mac in macs.macs { #expect(try attachment(macs, mac)?.clusterApproval == later) }
        // A day before the later one ends, the coordinator still lists it and serves nothing newer: it stays.
        let dayBefore = Date().timeIntervalSince1970 + 13.5 * 86_400
        #expect(macs.sync(.approvals([later]), leaderFacts: facts, followerFacts: facts, now: dayBefore) == .unchanged)
        // Once it ended, with no answer from the coordinator: removed on both Macs, said in one line.
        let after = Date().timeIntervalSince1970 + 15 * 86_400
        let removed = macs.sync(.unavailable("no answer"), leaderFacts: facts, followerFacts: facts, now: after)
        #expect(removed.changed && removed.line?.hasPrefix("The cluster approval later expired at") == true)
        #expect(removed.note == .some(removed.line))
        for mac in macs.macs { #expect(try attachment(macs, mac) == nil, "rank \(mac.rank) kept an ended approval") }
    }

    @Test func theFollowerRefusesATamperedEntryAndKeepsItsSetup() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let before = try macs.bytes(macs.follower), facts = try macs.facts()
        let genuine = macs.approval()
        let tampered = ClusterRuntimeApproval(id: genuine.id, model: genuine.model, generation: genuine.generation,
            placementPolicySHA256: genuine.placementPolicySHA256, artifactSHA256: genuine.artifactSHA256,
            nativeRuntimeSHA256: ClusterApprovalMacs.hash("9"), metallibSHA256: genuine.metallibSHA256,
            resourceLibrarySHA256: genuine.resourceLibrarySHA256, capabilitySHA256: genuine.capabilitySHA256,
            resourcePolicySHA256: genuine.resourcePolicySHA256, profileSHA256: genuine.profileSHA256, schedule: genuine.schedule,
            maximumTransportFrame: genuine.maximumTransportFrame, maximumPlaintext: genuine.maximumPlaintext,
            maximumRecords: genuine.maximumRecords, maximumCumulativePlaintext: genuine.maximumCumulativePlaintext,
            allowedNumericsClasses: genuine.allowedNumericsClasses, minimumMembers: genuine.minimumMembers,
            maximumMembers: genuine.maximumMembers, minimumMemberUsableBytes: genuine.minimumMemberUsableBytes, notAfter: genuine.notAfter)
        var command = ClusterServiceCommand(op: .approval)
        command.approval = tampered
        #expect(throws: (any Error).self) { try macs.cable(facts: facts)(command) }
        // A link that names this Mac itself, or a Mac outside the pairing, is refused the same way.
        command.approval = genuine
        command.approvalEdge = ClusterEdge(peerPin: macs.follower.pin, transport: "rdma", measuredMbps: 1, measuredRTTMicros: 1)
        #expect(throws: (any Error).self) { try macs.cable(facts: facts)(command) }
        command.approvalEdge = ClusterEdge(peerPin: ClusterApprovalMacs.hash("c"), transport: "rdma", measuredMbps: 1, measuredRTTMicros: 1)
        #expect(throws: (any Error).self) { try macs.cable(facts: facts)(command) }
        #expect(try macs.bytes(macs.follower) == before)
        // The genuine entry with the leader as its link is saved.
        command.approvalEdge = ClusterEdge(peerPin: macs.leader.pin, transport: "rdma", measuredMbps: 1, measuredRTTMicros: 1)
        try macs.cable(facts: facts)(command)
        #expect(try attachment(macs, macs.follower)?.clusterApproval == genuine)
    }

    @Test func aMacWhoseMemberWouldRefuseToStartSavesNothing() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let before = try macs.bytes(macs.leader), saved = try macs.saved(macs.leader), facts = try macs.facts()
        // No chip class: the member's own start refuses its rank (`requireLocalRankGranted`).
        #expect(throws: (any Error).self) {
            _ = try ClusterApprovalAttachment.attachment(for: macs.approval(), saved: saved, paths: macs.leader.paths,
                pairingStore: macs.leader.pairing, edge: nil, now: Date().timeIntervalSince1970, chipClass: nil, facts: { _ in facts })
        }
        // An ended approval, and one for another schedule, are refused before any file is read.
        for approval in [macs.approval(endsIn: -1), macs.approval(schedule: 2)] {
            #expect(throws: (any Error).self) {
                _ = try ClusterApprovalAttachment.attachment(for: approval, saved: saved, paths: macs.leader.paths,
                    pairingStore: macs.leader.pairing, edge: nil, now: Date().timeIntervalSince1970,
                    chipClass: ClusterApprovalMacs.chip, facts: { _ in facts })
            }
        }
        // A pairing store that holds no pairing for this setup's link edge.
        let stranger = ClusterPairingProviderTests.temporaryStore()
        #expect(throws: (any Error).self) {
            _ = try ClusterApprovalAttachment.attachment(for: macs.approval(), saved: saved, paths: macs.leader.paths,
                pairingStore: stranger, edge: nil, now: Date().timeIntervalSince1970, chipClass: ClusterApprovalMacs.chip,
                facts: { _ in facts })
        }
        // An installation that cannot be described.
        #expect(throws: (any Error).self) {
            _ = try ClusterApprovalAttachment.attachment(for: macs.approval(), saved: saved, paths: macs.leader.paths,
                pairingStore: macs.leader.pairing, edge: nil, now: Date().timeIntervalSince1970, chipClass: ClusterApprovalMacs.chip,
                facts: { _ in throw ClusterConfigurationError.invalid("the worker did not answer") })
        }
        #expect(try macs.bytes(macs.leader) == before)
    }

    /// A model approval names no build: both Macs save it from a mixed answer without describing their installed
    /// runtime, and after an update re-adopts the setups for a new worker the next check finds the same entry again,
    /// while the build-pinned entry of the old build no longer matches.
    @Test func aModelApprovalIsSavedWithoutBuildFactsAndFoundAgainAfterAnUpdate() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        let model = macs.modelApproval()
        // The old build's own entry for the same model and schedule, ending later: it would win while it matched.
        let pinnedOld = macs.approval(endsIn: 20 * 86_400, id: "devnet/old-build/fixture-qwen/s1")
        mock.setClusterApprovals(body: try ClusterApprovalMacs.body([macs.approval(schedule: 2), model, macs.modelApproval(schedule: 2)]))
        let fetched = await ClusterApprovalFetch.fetch(coordinatorURL: url)
        guard case .approvals(let listed) = fetched else { Issue.record("a mixed answer was refused: \(fetched)"); return }
        #expect(listed.map(\.isModelApproval) == [false, true, true])
        let described = ClusterApprovalRecorder<Int>()
        let describe: (ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts = { _ in
            described.append(1); throw ClusterConfigurationError.invalid("a model approval needs no build facts")
        }
        let result = macs.sync(fetched, describe: describe, followerDescribe: describe)
        #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(model), note: .some(nil)))
        #expect(described.values.isEmpty)
        for mac in macs.macs {
            let saved = try #require(try attachment(macs, mac), "rank \(mac.rank) saved no approval")
            #expect(saved.schema == ClusterNativeMemberAttachment.rosterSchemaName && saved.clusterApproval == model)
            #expect(try saved.policyBytes == model.canonicalPolicy())
            // The saved setup holds the 14 fields and reads back to the same bytes.
            let setup = try macs.saved(mac), file = try macs.bytes(mac)[1]
            #expect(try ClusterConfigurationCodec.encode(setup.configuration, capability: setup.capability,
                capabilitySHA256: setup.configuration.capabilitySHA256) == file)
            let object = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
            let entry = try #require((object["nativeMember"] as? [String: Any])?["clusterApproval"] as? [String: Any])
            #expect(Set(entry.keys) == ClusterRuntimeApproval.modelFields)
        }

        // The update: both setups re-adopted for the new build's worker, with no approval.
        let newWorker = ClusterApprovalMacs.hash("9")
        try macs.readopt(runtime: newWorker)
        for mac in macs.macs { #expect(try attachment(macs, mac) == nil) }
        var watch = ClusterApprovalCheck.Watch()
        let step = ClusterApprovalCheck.step(saved: try macs.saved(macs.leader), fetched: .approvals([pinnedOld, model]),
            setAside: nil, scope: .publicServing, memberQuickEnds: 0, peerApprovalID: .some(nil), watch: &watch,
            clock: 0, grace: 600, now: Date().timeIntervalSince1970, facts: { _ in try macs.facts() })
        #expect(step == .save(model))
        let updated = try macs.facts()
        #expect(macs.sync(.approvals([pinnedOld, model]), leaderFacts: updated, followerFacts: updated).changed)
        for mac in macs.macs {
            let saved = try macs.saved(mac)
            #expect(saved.configuration.nativeMember?.clusterApproval == model)
            #expect(saved.capability.runtimeBinarySHA256 == newWorker)
        }
        await mock.shutdown()
    }

    /// The owner's own admission of a committed start (`DistributedInstalledOwner.memberAuthorizer`) under a saved
    /// model approval: the start must carry this Mac's own setup's runtime block, the one its member registers.
    @Test func theOwnerAdmitsAStartUnderAModelApprovalOnlyWithItsSetupsRuntime() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let model = macs.modelApproval(), facts = try macs.facts()
        #expect(macs.sync(.approvals([model]), leaderFacts: facts, followerFacts: facts).changed)
        let saved = try macs.saved(macs.leader), member = try #require(saved.configuration.nativeMember)
        let plan = try DistributedInstalledPlan(saved: saved, paths: macs.leader.paths)
        let admit = try DistributedInstalledOwner.memberAuthorizer(plan: plan, attachment: member)
        let own = DistributedInstalledNativeStart.runtimeBlock(plan: plan)
        #expect(own.nativeRuntimeSHA256 == saved.capability.runtimeBinarySHA256)
        func start(_ runtime: ClusterPlan.Runtime) throws -> ClusterNativeAuthorizationStart {
            func bytes(_ hex: String) throws -> Data { try #require(NativePairMemberPolicy.digest(hex: hex)) }
            let common = try ClusterNativeAuthorizationCommon(epoch: UUID(), membershipGeneration: 7, nativePolicyGeneration: model.generation,
                membershipTranscriptSHA256: memberDigest("model-approval-membership"),
                approvedNativeBindingSHA256: Data(SHA256.hash(data: try member.policyBytes)),
                planSHA256: try bytes(plan.partition.planSHA256), artifactSHA256: try bytes(model.artifactSHA256),
                nativeRuntimeSHA256: try bytes(runtime.nativeRuntimeSHA256), capabilitySHA256: try bytes(runtime.capabilitySHA256),
                resourcePolicySHA256: try bytes(runtime.resourcePolicySHA256), profileSHA256: try bytes(runtime.profileSHA256),
                schedule: .serial, maximumTransportFrameBytes: Int(model.maximumTransportFrame),
                limits: .init(maximumPlaintextBytes: Int(model.maximumPlaintext), maximumRecordsPerDirection: model.maximumRecords,
                              maximumCumulativePlaintextBytesPerDirection: model.maximumCumulativePlaintext))
            return try .init(common: common, rank: plan.configuration.localRank, ownerIncarnation: UUID(), leaseID: UUID(),
                             launchID: UUID())
        }
        try admit(try start(own))
        let other = ClusterApprovalMacs.hash("9")
        for runtime in [
            ClusterPlan.Runtime(nativeRuntimeSHA256: other, capabilitySHA256: own.capabilitySHA256,
                                resourcePolicySHA256: own.resourcePolicySHA256, profileSHA256: own.profileSHA256),
            ClusterPlan.Runtime(nativeRuntimeSHA256: own.nativeRuntimeSHA256, capabilitySHA256: own.capabilitySHA256,
                                resourcePolicySHA256: other, profileSHA256: own.profileSHA256),
        ] {
            #expect(throws: ClusterConfigurationError.self) { try admit(try start(runtime)) }
        }
    }

    @Test func aModelApprovalForAnotherArtifactIsSavedOnNeitherMac() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let before = try macs.macs.map(macs.bytes), saved = try macs.saved(macs.leader)
        let other = macs.modelApproval(artifact: ClusterApprovalMacs.hash("9"))
        let refusal = "the approval's artifact_sha256 differs from this Mac's setup"
        let mine = #expect(throws: (any Error).self) {
            _ = try ClusterApprovalAttachment.attachment(for: other, saved: saved, paths: macs.leader.paths,
                pairingStore: macs.leader.pairing, edge: nil, now: Date().timeIntervalSince1970, chipClass: ClusterApprovalMacs.chip,
                facts: { _ in throw ClusterConfigurationError.invalid("a model approval needs no build facts") })
        }
        #expect(mine.map(ClusterApprovalSync.refusal) == refusal)
        // The other Mac refuses it the same way when its leader sends it.
        var command = ClusterServiceCommand(op: .approval)
        command.approval = other
        command.approvalEdge = ClusterEdge(peerPin: macs.leader.pin, transport: "rdma", measuredMbps: 1, measuredRTTMicros: 1)
        let cable = macs.cable(facts: try macs.facts())
        let theirs = #expect(throws: (any Error).self) { try cable(command) }
        #expect(theirs.map(ClusterApprovalSync.refusal)?.hasSuffix(refusal) == true)
        #expect(try macs.macs.map(macs.bytes) == before)
    }

    @Test func aFollowerThatCannotBeReachedLeavesBothMacsWithoutTheApproval() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let before = try macs.macs.map(macs.bytes), facts = try macs.facts()
        let result = ClusterApprovalSync.run(fetched: .approvals([macs.approval()]), paths: macs.leader.paths,
            providerConfiguration: macs.leader.provider, pairingStore: macs.leader.pairing, scratch: macs.leader.scratch,
            now: Date().timeIntervalSince1970,
            sendToPeer: { _ in throw ClusterSetupFailure("the other Mac's cluster service did not answer on the cable") },
            chipClass: ClusterApprovalMacs.chip, facts: { _ in facts })
        #expect(!result.changed && result.line?.contains("the other Mac did not answer over the cable") == true)
        #expect(try macs.macs.map(macs.bytes) == before)
    }

    /// This Mac's device journal as a stop leaves it when it ends the owner before its worker's cleanup is published:
    /// not empty, so every save of this Mac's setup is refused ("Unresolved native ownership journal").
    private func strandJournal(_ mac: ClusterApprovalMacs.Mac) throws -> URL {
        try FileManager.default.createDirectory(at: mac.paths.deviceDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let journal = mac.paths.deviceLeaseFile
        #expect(FileManager.default.createFile(atPath: journal.path, contents: Data("fixture: an earlier session\n".utf8),
                                               attributes: [.posixPermissions: 0o600]))
        return journal
    }

    private func run(_ macs: ClusterApprovalMacs, _ approval: ClusterRuntimeApproval, facts: ClusterRuntimeApprovalFacts,
                     journalRecovery: ClusterApprovalJournalRecovery) -> ClusterApprovalSync.Result {
        ClusterApprovalSync.run(fetched: .approvals([approval]), paths: macs.leader.paths, providerConfiguration: macs.leader.provider,
            pairingStore: macs.leader.pairing, scratch: macs.leader.scratch, now: Date().timeIntervalSince1970,
            sendToPeer: macs.cable(facts: facts), chipClass: ClusterApprovalMacs.chip, facts: { _ in facts },
            journalRecovery: journalRecovery)
    }

    /// The guided setup's approval step saves right after its own stop, and a stop that lands seconds after the pair came
    /// up can strand this Mac's device journal, which then refused that save: the pair served on its local API only
    /// (a DevNet pair, 2026-11-19). The save runs the journal's recovery once and saves again: both Macs carry the
    /// approval, and the line says what the recovery did first.
    @Test func aSaveTheDeviceJournalRefusedRecoversItOnceAndSavesAgain() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        macs.recordLinkProbe()
        let approval = macs.approval(), facts = try macs.facts()
        let journal = try strandJournal(macs.leader)
        let recoveries = ClusterApprovalRecorder<String>()
        let result = run(macs, approval, facts: facts, journalRecovery: .init { paths in
            recoveries.append(paths.deviceLeaseFile.path)
            guard let handle = try? FileHandle(forWritingTo: paths.deviceLeaseFile) else { return nil }
            try? handle.truncate(atOffset: 0); try? handle.close()
            return "fixture: the journal is cleared"
        })
        #expect(result == .init(changed: true, line: "fixture: the journal is cleared; " + ClusterApprovalLifetime.offeredLine(approval),
                                note: .some(nil)))
        #expect(recoveries.values == [journal.path])
        for mac in macs.macs { #expect(try attachment(macs, mac)?.clusterApproval == approval, "rank \(mac.rank)") }
    }

    /// A recovery that refuses (something of the earlier session still runs) changes nothing: the save is refused as
    /// before, once, and neither Mac carries the approval.
    @Test func aSaveWhoseJournalRecoveryRefusesSavesNothingAndSaysWhy() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts()
        let journal = try strandJournal(macs.leader)
        let recoveries = ClusterApprovalRecorder<String>()
        let result = run(macs, approval, facts: facts, journalRecovery: .init { paths in
            recoveries.append(paths.deviceLeaseFile.path)
            return nil
        })
        #expect(!result.changed && result.line?.hasPrefix(
            "Not offered for pairing: this Mac could not save its setup: Unresolved native ownership journal") == true,
            "\(String(describing: result.line))")
        #expect(recoveries.values.count == 1)
        #expect(try Data(contentsOf: journal) == Data("fixture: an earlier session\n".utf8))
        for mac in macs.macs { #expect(try attachment(macs, mac)?.clusterApproval == nil, "rank \(mac.rank)") }
    }

    /// With `DARKBLOOM_CLUSTER_JOURNAL_AUTO_RECOVER` off, a save the journal refused recovers nothing, as before.
    @Test func withItsSwitchOffASaveTheJournalRefusedRecoversNothing() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts()
        let journal = try strandJournal(macs.leader)
        let result = run(macs, approval, facts: facts, journalRecovery: .live(enabled: false))
        #expect(!result.changed && result.line?.contains("Unresolved native ownership journal") == true, "\(String(describing: result.line))")
        #expect(try Data(contentsOf: journal) == Data("fixture: an earlier session\n".utf8))
        for mac in macs.macs { #expect(try attachment(macs, mac)?.clusterApproval == nil, "rank \(mac.rank)") }
    }
}
