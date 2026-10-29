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
                      setAside: ClusterSetupRecord.ApprovalSetAside? = nil, quickEnds: Int = 0,
                      scope: ClusterServingScope = .publicServing, _ watched: Watched, clock: Double) throws -> ClusterApprovalCheck.Step {
        let facts = try macs.facts()
        return ClusterApprovalCheck.step(saved: try macs.saved(macs.leader), fetched: fetched, setAside: setAside, scope: scope,
                                         memberQuickEnds: quickEnds, watch: &watched.watch, clock: clock, grace: grace,
                                         now: Date().timeIntervalSince1970, facts: { _ in facts })
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
}
