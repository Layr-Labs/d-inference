import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
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
        let sent = ClusterApprovalSent(), facts = try macs.facts()
        let result = macs.sync(fetched, leaderFacts: facts, followerFacts: facts, sent: sent)
        #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(serial), note: .some(nil)))
        #expect(sent.commands.map(\.op) == [.approval] && sent.commands.first?.approval == serial)

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
        #expect(try macs.macs.map(macs.bytes) == before && sent.commands.count == 1)
        await mock.shutdown()
    }

    @Test func aCoordinatorWithoutPairingLeavesBothSetupsByteForByte() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        let before = try macs.macs.map(macs.bytes)
        let fetched = await ClusterApprovalFetch.fetch(coordinatorURL: url)
        #expect(fetched == .notOffered)
        let sent = ClusterApprovalSent(), facts = try macs.facts()
        #expect(macs.sync(fetched, leaderFacts: facts, followerFacts: facts, sent: sent) == .unchanged)
        #expect(try macs.macs.map(macs.bytes) == before && sent.commands.isEmpty)
        await mock.shutdown()
    }

    @Test func anEntryWithAnyDigestThatIsNotThisMacsIsSavedOnNeitherMac() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let before = try macs.macs.map(macs.bytes), approval = macs.approval(), facts = try macs.facts()
        for field in ClusterApprovalMacs.blockFields {
            // The leader's own check refuses before anything is sent.
            let sent = ClusterApprovalSent()
            let mine = macs.sync(.approvals([approval]), leaderFacts: try macs.facts(differing: field), followerFacts: facts, sent: sent)
            #expect(!mine.changed && sent.commands.isEmpty, "\(field)")
            #expect(mine.line?.contains("this Mac's check refused it: the approval's \(field) differ") == true, "\(mine.line ?? "")")
            // The follower's own check refuses it: the leader then saves nothing either.
            let theirs = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: try macs.facts(differing: field))
            #expect(!theirs.changed, "\(field)")
            #expect(theirs.line?.contains(ClusterApprovalSync.peerRefusalPrefix + "the approval's \(field) differ") == true, "\(theirs.line ?? "")")
            #expect(try macs.macs.map(macs.bytes) == before, "\(field) left a saved approval")
        }
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
        // A day before the later one ends, the coordinator offers nothing newer: it stays.
        let dayBefore = Date().timeIntervalSince1970 + 13.5 * 86_400
        #expect(macs.sync(.notOffered, leaderFacts: facts, followerFacts: facts, now: dayBefore) == .unchanged)
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
}
