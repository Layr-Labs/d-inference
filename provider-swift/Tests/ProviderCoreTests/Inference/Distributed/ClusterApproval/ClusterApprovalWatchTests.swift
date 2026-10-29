import Foundation
import Testing
@testable import ProviderCore

/// The control leader's watch over the coordinator of an offered pair (`ClusterApprovalSync.step`, `serveLocally`):
/// no answer for the absence grace makes the pair serve on the leader's local API, and an answer offers it again. The
/// control clock is a value the test gives; each Mac's stores, files and pairing are real, and the follower's side is
/// its cluster service's own `approval` handling.
@Suite("Cluster approval coordinator watch", .serialized)
struct ClusterApprovalWatchTests {
    private let grace = ClusterControlNode.defaultSoloGraceSeconds
    private let noAnswer = ClusterApprovalFetch.Outcome.unreachable("Could not connect to the server.")

    /// Two Macs whose setups both carry `approval`, offered to the coordinator.
    private func offered() throws -> (ClusterApprovalMacs, ClusterRuntimeApproval, ClusterRuntimeApprovalFacts) {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let approval = macs.approval(), facts = try macs.facts()
        #expect(macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts).changed)
        return (macs, approval, facts)
    }

    /// The leader's watch between checks, as the cluster service keeps it.
    private final class Watched {
        var watch = ClusterApprovalSync.Watch()
    }

    private func step(_ macs: ClusterApprovalMacs, _ fetched: ClusterApprovalFetch.Outcome, parked: ClusterRuntimeApproval? = nil,
                      scope: ClusterServingScope = .publicServing, _ watched: Watched, clock: Double) throws -> ClusterApprovalSync.Step {
        let facts = try macs.facts()
        return ClusterApprovalSync.step(saved: try macs.saved(macs.leader), fetched: fetched, parked: parked, scope: scope,
                                        watch: &watched.watch, clock: clock, grace: grace, now: Date().timeIntervalSince1970,
                                        facts: { _ in facts })
    }

    private func serveLocally(_ macs: ClusterApprovalMacs, _ approval: ClusterRuntimeApproval, facts: ClusterRuntimeApprovalFacts,
                              sent: ClusterApprovalRecorder<ClusterServiceCommand>? = nil, scratch: URL? = nil,
                              sendToPeer: ((ClusterServiceCommand) throws -> Void)? = nil) -> ClusterApprovalSync.Result {
        ClusterApprovalSync.serveLocally(approval, grace: grace, paths: macs.leader.paths, providerConfiguration: macs.leader.provider,
            pairingStore: macs.leader.pairing, scratch: scratch ?? macs.leader.scratch,
            sendToPeer: sendToPeer ?? macs.cable(facts: facts, sent: sent))
    }

    @Test func anOfferedPairKeepsItsApprovalUntilTheCoordinatorHasNotAnsweredForTheGrace() throws {
        let (macs, _, _) = try offered()
        let before = try macs.macs.map(macs.bytes)
        let watch = Watched()
        #expect(try step(macs, noAnswer, watch, clock: 1_000) == .keep)
        #expect(try step(macs, noAnswer, watch, clock: 1_000 + grace - 1) == .keep)
        // An answer in between starts the grace again: no answer from 1 300 on is not yet the grace at 1 899.
        #expect(try step(macs, .notOffered, watch, clock: 1_200) == .keep)
        #expect(watch.watch.unreachableSince == nil)
        #expect(try step(macs, noAnswer, watch, clock: 1_300) == .keep)
        #expect(try step(macs, noAnswer, watch, clock: 1_300 + grace - 1) == .keep)
        // An answer that is not usable (an HTTP error) is an answer: the coordinator is reachable.
        #expect(try step(macs, .unavailable("HTTP 500"), watch, clock: 1_300 + grace) == .keep)
        #expect(try macs.macs.map(macs.bytes) == before)
    }

    @Test func atTheGraceBothMacsServeOnTheLeadersLocalAPI() throws {
        let (macs, approval, facts) = try offered()
        let watch = Watched()
        #expect(try step(macs, noAnswer, watch, clock: 1_000) == .keep)
        #expect(try step(macs, noAnswer, watch, clock: 1_000 + grace) == .serveLocally(approval))
        // Only a pair offered now falls back: one that serves locally only by choice keeps its setup as it is.
        let local = Watched()
        #expect(try step(macs, noAnswer, scope: .localOnly(bind: "127.0.0.1"), local, clock: 0) == .keep)
        #expect(try step(macs, noAnswer, scope: .localOnly(bind: "127.0.0.1"), local, clock: grace) == .keep)

        // The other Mac cannot be told: neither Mac changes, so neither serves in another mode than the other.
        let before = try macs.macs.map(macs.bytes)
        let untold = serveLocally(macs, approval, facts: facts,
            sendToPeer: { _ in throw ClusterSetupFailure("the other Mac's cluster service did not answer on the cable") })
        #expect(!untold.changed && untold.note == nil && untold.line?.contains("the pair stays offered") == true)
        #expect(try macs.macs.map(macs.bytes) == before)
        // This Mac cannot save (its scratch folder is a file): the other Mac, which already saved without it, gets the
        // approval back and checks it again, so both Macs stay offered.
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
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank) stayed offered") }
        // Serving locally, the pair has nothing to fall back from while the coordinator still gives no answer.
        #expect(try step(macs, noAnswer, parked: approval, watch, clock: 1_000 + 2 * grace) == .keep)
    }

    @Test func whenTheCoordinatorAnswersAgainThePairIsOfferedAgainWithTheApprovalSetAside() throws {
        let (macs, approval, facts) = try offered()
        _ = serveLocally(macs, approval, facts: facts)
        let watch = Watched()
        // A coordinator that answers 404 now (or any answer) offers the pair again with the approval it set aside.
        #expect(try step(macs, .notOffered, parked: approval, watch, clock: 0) == .save(approval))
        // A later approval the coordinator offers now is taken instead.
        let later = macs.approval(endsIn: 20 * 86_400, id: "later")
        #expect(try step(macs, .approvals([later]), parked: approval, watch, clock: 0) == .save(later))
        // Not while it still gives no answer, not once the approval set aside ended, not when it serves locally by choice.
        #expect(try step(macs, noAnswer, parked: approval, watch, clock: 0) == .keep)
        #expect(try step(macs, .notOffered, parked: macs.approval(endsIn: -60), watch, clock: 0) == .keep)
        #expect(try step(macs, .notOffered, parked: approval, scope: .localOnly(bind: "127.0.0.1"), watch, clock: 0) == .keep)

        // Each Mac checks the approval against its own files again before it saves it: a follower whose files
        // differ now refuses, and neither Mac is offered.
        let before = try macs.macs.map(macs.bytes)
        let refused = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: try macs.facts(differing: "metallib_sha256"))
        #expect(!refused.changed)
        #expect(try macs.macs.map(macs.bytes) == before)
        let result = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts)
        #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(approval), note: .some(nil)))
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember?.clusterApproval == approval) }
    }
}
