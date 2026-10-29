import Foundation
import Testing
@testable import ProviderCore

/// The control leader's check of a registered pair (`ClusterApprovalCheck.step`, `ClusterApprovalSync.serveLocally`):
/// no answer for the absence grace, an entry the coordinator no longer lists, or parts that keep failing make the pair
/// serve on the leader's local API, and a matching entry listed again registers it again. The control clock is a
/// value the test gives; each Mac's stores, files and pairing are real, and the follower's side is its cluster
/// service's own `approval` handling.
@Suite("Cluster approval coordinator watch", .serialized)
struct ClusterApprovalWatchTests {
    private let grace = ClusterControlNode.defaultSoloGraceSeconds
    private let noAnswer = ClusterApprovalFetch.Outcome.unreachable("Could not connect to the server.")

    /// Two Macs whose setups both carry `approval`, registered with the coordinator.
    private func offered() throws -> (ClusterApprovalMacs, ClusterRuntimeApproval, ClusterRuntimeApprovalFacts) {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts()
        #expect(macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts).changed)
        return (macs, approval, facts)
    }

    /// The leader's watch between checks, as the cluster service keeps it.
    private final class Watched {
        var watch = ClusterApprovalCheck.Watch()
    }

    private func step(_ macs: ClusterApprovalMacs, _ fetched: ClusterApprovalFetch.Outcome,
                      setAside: ClusterSetupRecord.ApprovalSetAside? = nil, quickEnds: Int = 0, peer: String?? = nil,
                      scope: ClusterServingScope = .publicServing, _ watched: Watched, clock: Double) throws -> ClusterApprovalCheck.Step {
        let facts = try macs.facts()
        return ClusterApprovalCheck.step(saved: try macs.saved(macs.leader), fetched: fetched, setAside: setAside, scope: scope,
                                         memberQuickEnds: quickEnds, peerApprovalID: peer, watch: &watched.watch, clock: clock,
                                         grace: grace, now: Date().timeIntervalSince1970, facts: { _ in facts })
    }

    /// The other Mac's saved cluster approval ID, as its status reports it.
    private func peerID(_ macs: ClusterApprovalMacs) throws -> String?? {
        .some(try macs.saved(macs.follower).configuration.nativeMember?.clusterApproval?.id)
    }

    private func converge(_ macs: ClusterApprovalMacs, _ target: ClusterRuntimeApproval?,
                          followerFacts: ClusterRuntimeApprovalFacts) -> ClusterApprovalSync.Result {
        ClusterApprovalSync.converge(target, paths: macs.leader.paths, providerConfiguration: macs.leader.provider,
            pairingStore: macs.leader.pairing, scratch: macs.leader.scratch, sendToPeer: macs.cable(facts: followerFacts))
    }

    private func serveLocally(_ macs: ClusterApprovalMacs, _ approval: ClusterRuntimeApproval, facts: ClusterRuntimeApprovalFacts,
                              reason: ClusterApprovalFallback = .unreachable,
                              sent: ClusterApprovalRecorder<ClusterServiceCommand>? = nil, scratch: URL? = nil,
                              sendToPeer: ((ClusterServiceCommand) throws -> Void)? = nil) -> ClusterApprovalSync.Result {
        ClusterApprovalSync.serveLocally(approval, line: reason.line(approval, grace: grace), paths: macs.leader.paths,
            providerConfiguration: macs.leader.provider, pairingStore: macs.leader.pairing, scratch: scratch ?? macs.leader.scratch,
            sendToPeer: sendToPeer ?? macs.cable(facts: facts, sent: sent))
    }

    @Test func anOfferedPairKeepsItsApprovalUntilTheCoordinatorHasNotAnsweredForTheGrace() throws {
        let (macs, approval, _) = try offered()
        let before = try macs.macs.map(macs.bytes)
        let watch = Watched()
        #expect(try step(macs, noAnswer, watch, clock: 1_000) == .keep)
        #expect(try step(macs, noAnswer, watch, clock: 1_000 + grace - 1) == .keep)
        // An answer that lists the approval starts the grace again: no answer from 1 300 on is not yet the grace at 1 899.
        #expect(try step(macs, .approvals([approval]), watch, clock: 1_200) == .keep)
        #expect(watch.watch.unreachableSince == nil)
        #expect(try step(macs, noAnswer, watch, clock: 1_300) == .keep)
        #expect(try step(macs, noAnswer, watch, clock: 1_300 + grace - 1) == .keep)
        // An answer that is not usable (an HTTP error) is an answer, and says nothing about the approval.
        #expect(try step(macs, .unavailable("HTTP 500"), watch, clock: 1_300 + grace) == .keep)
        #expect(try macs.macs.map(macs.bytes) == before)
    }

    @Test func atTheGraceBothMacsServeOnTheLeadersLocalAPI() throws {
        let (macs, approval, facts) = try offered()
        let watch = Watched()
        #expect(try step(macs, noAnswer, watch, clock: 1_000) == .keep)
        #expect(try step(macs, noAnswer, watch, clock: 1_000 + grace) == .serveLocally(approval, .unreachable))
        // Only a pair offered now falls back: one that serves locally only by choice keeps its setup as it is.
        let local = Watched()
        #expect(try step(macs, noAnswer, scope: .localOnly(bind: "127.0.0.1"), local, clock: 0) == .keep)
        #expect(try step(macs, noAnswer, scope: .localOnly(bind: "127.0.0.1"), local, clock: grace) == .keep)

        // The other Mac cannot be told: neither Mac changes, so neither serves in another mode than the other.
        let before = try macs.macs.map(macs.bytes)
        let untold = serveLocally(macs, approval, facts: facts,
            sendToPeer: { _ in throw ClusterSetupFailure("the other Mac's cluster service did not answer on the cable") })
        #expect(!untold.changed && untold.note == nil && untold.line?.contains("stays registered") == true)
        #expect(try macs.macs.map(macs.bytes) == before)
        // This Mac cannot save (its scratch folder is a file): the other Mac, which already saved without it, gets the
        // approval back and checks it again, so both Macs stay registered.
        let blocked = macs.leader.home.appendingPathComponent("scratch-is-a-file")
        try Data("x".utf8).write(to: blocked)
        let unsaved = serveLocally(macs, approval, facts: facts, scratch: blocked)
        #expect(!unsaved.changed && unsaved.line?.contains("this Mac could not save its setup") == true, "\(unsaved.line ?? "")")
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember?.clusterApproval == approval, "rank \(mac.rank)") }

        let sent = ClusterApprovalRecorder<ClusterServiceCommand>()
        let result = serveLocally(macs, approval, facts: facts, sent: sent)
        #expect(result.changed && result.note == .some(result.line))
        #expect(result.line?.hasPrefix("The coordinator has not answered for 10 minutes: the pair serves on the leader's local API") == true,
                "\(result.line ?? "")")
        #expect(sent.values.map(\.op) == [.approval] && sent.values.first?.approval == nil)
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank) stayed registered") }
        // Serving locally, the pair has nothing to fall back from while the coordinator still gives no answer.
        let setAside = ClusterSetupRecord.ApprovalSetAside(approval: approval, reason: .unreachable)
        #expect(try step(macs, noAnswer, setAside: setAside, watch, clock: 1_000 + 2 * grace) == .keep)
    }

    @Test func anApprovalTheCoordinatorNoLongerListsMakesThePairServeLocally() throws {
        let (macs, approval, facts) = try offered()
        let watch = Watched()
        // A 200 without the saved approval, and a 404, both withdraw it (no other matching entry is served).
        let another = macs.approval(model: "other/model", id: "other")
        #expect(try step(macs, .approvals([another]), watch, clock: 0) == .serveLocally(approval, .withdrawn))
        #expect(try step(macs, .notOffered, watch, clock: 0) == .serveLocally(approval, .withdrawn))
        // A later matching entry in place of the saved one is saved instead.
        let later = macs.approval(endsIn: 20 * 86_400, id: "later")
        #expect(try step(macs, .approvals([later]), watch, clock: 0) == .save(later))

        let result = serveLocally(macs, approval, facts: facts, reason: .withdrawn)
        #expect(result.changed && result.line == ClusterApprovalFallback.withdrawn.line(approval, grace: grace))
        #expect(result.line?.hasPrefix("The coordinator no longer lists cluster approval \(approval.id)") == true)
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank) stayed registered") }
    }

    @Test func aMatchingEntryListedAgainRegistersThePairAgain() throws {
        let (macs, approval, facts) = try offered()
        _ = serveLocally(macs, approval, facts: facts, reason: .withdrawn)
        let watch = Watched(), withdrawn = ClusterSetupRecord.ApprovalSetAside(approval: approval, reason: .withdrawn)
        // While the coordinator lists nothing for it, or gives no answer, the pair stays local.
        #expect(try step(macs, .notOffered, setAside: withdrawn, watch, clock: 0) == .keep)
        #expect(try step(macs, noAnswer, setAside: withdrawn, watch, clock: 0) == .keep)
        // Listed again: saved again. A later matching one is taken in its place.
        #expect(try step(macs, .approvals([approval]), setAside: withdrawn, watch, clock: 0) == .save(approval))
        let later = macs.approval(endsIn: 20 * 86_400, id: "later")
        #expect(try step(macs, .approvals([approval, later]), setAside: withdrawn, watch, clock: 0) == .save(later))
        // Not once it ended, and not when the cluster serves locally by choice.
        #expect(try step(macs, .approvals([macs.approval(endsIn: -60)]), setAside: withdrawn, watch, clock: 0) == .keep)
        #expect(try step(macs, .approvals([approval]), setAside: withdrawn, scope: .localOnly(bind: "127.0.0.1"), watch, clock: 0) == .keep)

        // Each Mac checks the approval against its own files again before it saves it: a follower whose files
        // differ now refuses, and neither Mac is registered.
        let before = try macs.macs.map(macs.bytes)
        let refused = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: try macs.facts(differing: "metallib_sha256"))
        #expect(!refused.changed)
        #expect(try macs.macs.map(macs.bytes) == before)
        let result = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts)
        #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(approval), note: .some(nil)))
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember?.clusterApproval == approval) }
    }

    @Test func partsThatKeepFailingMakeThePairServeLocallyAndTheApprovalIsNotTakenAgain() throws {
        let (macs, approval, facts) = try offered()
        let watch = Watched(), limit = ClusterControlSoloAdmission.maximumQuickEnds
        #expect(try step(macs, .approvals([approval]), quickEnds: limit - 1, watch, clock: 0) == .keep)
        #expect(try step(macs, .approvals([approval]), quickEnds: limit, watch, clock: 0) == .serveLocally(approval, .failing))
        // Whatever the coordinator says.
        #expect(try step(macs, noAnswer, quickEnds: limit, watch, clock: 0) == .serveLocally(approval, .failing))

        _ = serveLocally(macs, approval, facts: facts, reason: .failing)
        let failing = ClusterSetupRecord.ApprovalSetAside(approval: approval, reason: .failing)
        #expect(try step(macs, .approvals([approval]), setAside: failing, watch, clock: 0) == .keep)
        let later = macs.approval(endsIn: 20 * 86_400, id: "later")
        #expect(try step(macs, .approvals([approval, later]), setAside: failing, watch, clock: 0) == .save(later))

        // The count: quick ends in a row; a part that ran long, or one that ended because the coordinator was out of
        // reach (the no-answer grace handles that), starts it again.
        let unreachable = "Error: " + ClusterMemberControlError.coordinatorUnreachable.rawValue
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 0, ranSeconds: 5, lastError: "Error: Saved cluster approval does not cover") == 1)
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 2, ranSeconds: 5, lastError: nil) == 3)
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 2, ranSeconds: ClusterControlSoloAdmission.quickEndSeconds, lastError: nil) == 0)
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 2, ranSeconds: 31, lastError: unreachable) == 0)
    }

    @Test func aClusterThatServesLocallyOnlyNeverAsksTheCoordinatorAndChangesNothing() throws {
        let local = ClusterServingScope.localOnly(bind: "127.0.0.1")
        for first in [true, false] {
            for serving in [true, false] {
                for offered in [true, false] {
                    for setAside in [true, false] {
                        #expect(!ClusterApprovalCheck.asks(first: first, serving: serving, scope: local, offered: offered, setAside: setAside))
                    }
                }
            }
        }
        // Serving publicly: the first check asks; later ones only for a serving pair that is offered or set aside.
        #expect(ClusterApprovalCheck.asks(first: true, serving: false, scope: .publicServing, offered: false, setAside: false))
        #expect(!ClusterApprovalCheck.asks(first: false, serving: true, scope: .publicServing, offered: false, setAside: false))
        #expect(ClusterApprovalCheck.asks(first: false, serving: true, scope: .publicServing, offered: true, setAside: false))
        #expect(ClusterApprovalCheck.asks(first: false, serving: true, scope: .publicServing, offered: false, setAside: true))
        #expect(!ClusterApprovalCheck.asks(first: false, serving: false, scope: .publicServing, offered: true, setAside: true))

        // Even with a matching entry served and one set aside, a local-only step saves nothing.
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), watch = Watched()
        let setAside = ClusterSetupRecord.ApprovalSetAside(approval: approval, reason: .withdrawn)
        #expect(try step(macs, .approvals([approval]), watch, clock: 0) == .save(approval))
        #expect(try step(macs, .approvals([approval]), scope: local, watch, clock: 0) == .keep)
        #expect(try step(macs, .approvals([approval]), setAside: setAside, scope: local, watch, clock: 0) == .keep)
    }

    @Test func aLostReplyIsGivenBackAndTheNextCheckBringsBothMacsTogether() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts(), cable = macs.cable(facts: facts)
        func run(_ sendToPeer: (ClusterServiceCommand) throws -> Void) -> ClusterApprovalSync.Result {
            ClusterApprovalSync.run(fetched: .approvals([approval]), paths: macs.leader.paths, providerConfiguration: macs.leader.provider,
                pairingStore: macs.leader.pairing, scratch: macs.leader.scratch, now: Date().timeIntervalSince1970,
                sendToPeer: sendToPeer, chipClass: ClusterApprovalMacs.chip, facts: { _ in facts })
        }
        // The other Mac saves the approval but every reply is lost: the leader gives it its setup back (which it
        // also applies), and says the reply of the give-back was lost too. Neither Mac carries the approval.
        let lossy = run { command in
            try cable(command)
            throw ClusterSetupFailure("the other Mac's reply was lost")
        }
        #expect(!lossy.changed && lossy.line?.contains("did not answer over the cable") == true, "\(lossy.line ?? "")")
        #expect(lossy.line?.contains("giving the other Mac its setup back failed too") == true)
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank)") }

        // The cable drops after the other Mac saved the approval: the give-back never arrives.
        var delivered = 0
        let dropped = run { command in
            delivered += 1
            if delivered == 1 { try cable(command) }
            throw ClusterSetupFailure("the cable dropped")
        }
        #expect(!dropped.changed && dropped.line?.contains("the next check compares both Macs") == true, "\(dropped.line ?? "")")
        #expect(try macs.saved(macs.follower).configuration.nativeMember?.clusterApproval == approval)
        #expect(try macs.saved(macs.leader).configuration.nativeMember == nil)
        // The next check compares both Macs, keeps asking while they differ, and gives the other Mac none.
        let leaderSaved = try macs.saved(macs.leader), differing = try peerID(macs)
        #expect(ClusterApprovalCheck.macsDiffer(leaderSaved, peerApprovalID: differing))
        #expect(ClusterApprovalCheck.asks(first: false, serving: true, scope: .publicServing, offered: false, setAside: false,
                                          macsDiffer: true))
        #expect(try step(macs, .approvals([approval]), peer: differing, Watched(), clock: 0) == .converge(nil))
        #expect(converge(macs, nil, followerFacts: facts).changed)
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank)") }
        let settledLeader = try macs.saved(macs.leader), settledPeer = try peerID(macs)
        #expect(!ClusterApprovalCheck.macsDiffer(settledLeader, peerApprovalID: settledPeer))
        // A Mac that did not answer its status is not compared.
        #expect(!ClusterApprovalCheck.macsDiffer(leaderSaved, peerApprovalID: nil))

        // The leader is registered and the other Mac lost its copy: it is given the leader's, and checks it itself.
        #expect(macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts).changed)
        try cable(ClusterServiceCommand(op: .approval))
        let lostCopy = try peerID(macs)
        #expect(try step(macs, .approvals([approval]), peer: lostCopy, Watched(), clock: 0) == .converge(approval))
        #expect(converge(macs, approval, followerFacts: facts).changed)
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember?.clusterApproval == approval, "rank \(mac.rank)") }
        // When the other Mac's own check refuses it now, neither Mac carries it.
        try cable(ClusterServiceCommand(op: .approval))
        let refused = converge(macs, approval, followerFacts: try macs.facts(differing: "metallib_sha256"))
        #expect(refused.changed && refused.line?.contains("neither Mac carries cluster approval") == true, "\(refused.line ?? "")")
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank)") }
    }

    @Test func aPartsQuickEndsAreCountedFromItsOwnLogLinesOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rank-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("rank.log")
        // An earlier part ended because the coordinator was out of reach; then the next part starts writing here.
        try Data(("Error: " + ClusterMemberControlError.coordinatorUnreachable.rawValue + "\n").utf8).write(to: log)
        let offset = UInt64(try Data(contentsOf: log).count)
        // The next part ends quickly without an error line of its own: its end is not the coordinator's and counts.
        #expect(ClusterService.lastError(in: log, from: offset) == nil)
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 1, ranSeconds: 5,
                                                     lastError: ClusterService.lastError(in: log, from: offset)) == 2)
        // Its own error line is the one read.
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("Error: Saved cluster approval does not cover this Mac's chip\n".utf8))
        try handle.close()
        #expect(ClusterService.lastError(in: log, from: offset) == "Saved cluster approval does not cover this Mac's chip")
        // The whole log still names the earlier part's line before it.
        #expect(ClusterService.lastError(in: log)?.hasPrefix("Saved cluster approval") == true)
        #expect(ClusterService.lastError(in: log, from: offset + 4_096)?.hasPrefix("Saved cluster approval") == true,
                "a log shorter than the offset was replaced and is read whole")
    }

    @Test func aFollowerThatDoesNotReportItsApprovalIsNeverTakenForOneWithout() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts()
        #expect(macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts).changed)
        let leaderSaved = try macs.saved(macs.leader)
        func status(_ approvalID: String?) throws -> ClusterServiceStatus {
            var object: [String: Any] = ["serving": true, "sessionLeader": false, "child": ["running": true, "starts": 1]]
            if let approvalID { object["approvalID"] = approvalID }
            return try JSONDecoder().decode(ClusterServiceStatus.self, from: JSONSerialization.data(withJSONObject: object))
        }
        // An older follower build sends no field: unknown, never "no approval", so nothing converges.
        let older = ClusterApprovalCheck.peerApprovalID(try status(nil))
        #expect(older == nil)
        #expect(!ClusterApprovalCheck.macsDiffer(leaderSaved, peerApprovalID: older))
        #expect(try step(macs, .approvals([approval]), peer: older, Watched(), clock: 0) == .keep)
        // A follower that reports none ("") differs from the leader's approval; one that reports the same ID does not.
        let none = ClusterApprovalCheck.peerApprovalID(try status(""))
        #expect(none == .some(nil) && ClusterApprovalCheck.macsDiffer(leaderSaved, peerApprovalID: none))
        let same = ClusterApprovalCheck.peerApprovalID(try status(approval.id))
        #expect(same == .some(approval.id) && !ClusterApprovalCheck.macsDiffer(leaderSaved, peerApprovalID: same))
        // No answer at all is unknown too.
        #expect(ClusterApprovalCheck.peerApprovalID(nil) == nil)
    }

    @Test func convergingOnNoneAlsoClearsTheLeadersApprovalThatIsNotOffered() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let facts = try macs.facts(), approval = macs.approval()
        #expect(macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts).changed)
        // The other Mac lost its copy; the leader serves locally only now, so its own approval is not offered.
        try macs.cable(facts: facts)(ClusterServiceCommand(op: .approval))
        let local = ClusterServingScope.localOnly(bind: "127.0.0.1"), lost = try peerID(macs)
        #expect(try step(macs, .unavailable("not asked"), peer: lost, scope: local, Watched(), clock: 0) == .converge(nil))
        let result = converge(macs, nil, followerFacts: facts)
        #expect(result.changed && result.line?.hasSuffix("neither Mac carries one now") == true, "\(result.line ?? "")")
        // Both Macs hold none, so the next check finds no difference and does not repeat.
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank)") }
        let leaderSaved = try macs.saved(macs.leader), settled = try peerID(macs)
        #expect(!ClusterApprovalCheck.macsDiffer(leaderSaved, peerApprovalID: settled))
    }

    @Test func noPartStopsForAnApprovalTheLeadersOwnCheckRefuses() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts(), before = try macs.macs.map(macs.bytes)
        var stops = 0, serves = 0
        func apply(stop: () -> String?, leaderFacts: ClusterRuntimeApprovalFacts) -> ClusterApprovalSync.Result {
            ClusterApprovalSync.apply(.save(approval), grace: grace, paths: macs.leader.paths, providerConfiguration: macs.leader.provider,
                pairingStore: macs.leader.pairing, scratch: macs.leader.scratch, now: Date().timeIntervalSince1970,
                stop: stop, serve: { serves += 1 }, sendToPeer: macs.cable(facts: facts), chipClass: ClusterApprovalMacs.chip,
                facts: { _ in leaderFacts })
        }
        // The leader's own check refuses the entry: no part stops, nothing is sent, nothing starts again.
        let refused = apply(stop: { stops += 1; return nil }, leaderFacts: try macs.facts(differing: "metallib_sha256"))
        #expect(!refused.changed && stops == 0 && serves == 0)
        #expect(refused.line?.contains("this Mac's check refused it") == true, "\(refused.line ?? "")")
        #expect(try macs.macs.map(macs.bytes) == before)
        // The parts do not stop: nothing changes and nothing starts.
        let unstopped = apply(stop: { "a part did not stop within 5 minutes" }, leaderFacts: facts)
        #expect(!unstopped.changed && unstopped.line == "a part did not stop within 5 minutes" && serves == 0)
        #expect(try macs.macs.map(macs.bytes) == before)
        // Accepted: both parts stop once, both Macs save it, both parts start once.
        let saved = apply(stop: { stops += 1; return nil }, leaderFacts: facts)
        #expect(saved.changed && stops == 1 && serves == 1)
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember?.clusterApproval == approval, "rank \(mac.rank)") }
    }
}
