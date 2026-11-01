import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Which approval a setup keeps and for how long, and the one line each screen shows for it.
@Suite("Cluster approval lifetime")
struct ClusterApprovalLifetimeTests {
    private static let macs = Result { try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider") }
    private func macs() throws -> ClusterApprovalMacs { try Self.macs.get() }
    private let now = Date().timeIntervalSince1970

    @Test func selectionTakesThisModelScheduleAndFactsStillCurrentWithTheLatestEnd() throws {
        let m = try macs(), facts = try m.facts()
        let serial = m.approval(schedule: 1), lookahead = m.approval(schedule: 2)
        let other = m.approval(model: "other/model"), later = m.approval(endsIn: 20 * 86_400, id: "later")
        let ended = m.approval(endsIn: -60, id: "ended")
        let all = [lookahead, other, serial, later, ended]
        func select(_ approvals: [ClusterRuntimeApproval], _ schedule: ClusterPrefillSchedule,
                    facts: ClusterRuntimeApprovalFacts) -> ClusterRuntimeApproval? {
            ClusterApprovalLifetime.select(approvals, model: ClusterApprovalMacs.model, schedule: schedule,
                                           artifact: m.capability.artifactSHA256, facts: { facts }, now: now)
        }
        #expect(select(all, .serial, facts: facts) == later)
        #expect(select(all, .oneChunkLookahead, facts: facts) == lookahead)
        #expect(select([other, lookahead, ended], .serial, facts: facts) == nil)
        // An entry with any digest that is not this Mac's (another build, another copy of the model) is not taken.
        for field in ClusterApprovalMacs.blockFields {
            let differing = try m.facts(differing: field)
            #expect(select(all, .serial, facts: differing) == nil, "\(field)")
        }
    }

    /// A model approval names no build: it is taken for this setup's model, schedule and saved artifact without
    /// describing the installed runtime (the facts closure never runs), and a build-pinned entry is still matched
    /// on the facts, once, when it is listed beside it.
    @Test func aModelApprovalIsChosenWithoutBuildFacts() throws {
        let m = try macs(), artifact = m.capability.artifactSHA256
        var calls = 0
        func select(_ approvals: [ClusterRuntimeApproval], _ schedule: ClusterPrefillSchedule = .serial,
                    facts: ClusterRuntimeApprovalFacts? = nil) -> ClusterRuntimeApproval? {
            ClusterApprovalLifetime.select(approvals, model: ClusterApprovalMacs.model, schedule: schedule, artifact: artifact,
                                           facts: { calls += 1; return facts }, now: now)
        }
        let serial = m.modelApproval(), lookahead = m.modelApproval(schedule: 2)
        #expect(select([lookahead, serial]) == serial)
        #expect(select([lookahead, serial], .oneChunkLookahead) == lookahead)
        #expect(calls == 0)
        // Another artifact, another schedule, another model or an ended entry is not this setup's.
        #expect(select([m.modelApproval(artifact: ClusterApprovalMacs.hash("9"))]) == nil)
        #expect(select([lookahead]) == nil)
        #expect(select([m.modelApproval(model: "other/model")]) == nil)
        #expect(select([m.modelApproval(endsIn: -60)]) == nil)
        #expect(calls == 0)
        // Both shapes listed: the later end wins, and the facts are described once for both build-pinned entries.
        let facts = try m.facts()
        let pinnedLater = m.approval(endsIn: 20 * 86_400, id: "pinned-later"), pinned = m.approval(id: "pinned")
        #expect(select([serial, pinned, pinnedLater], facts: facts) == pinnedLater)
        #expect(calls == 1)
        let modelLater = m.modelApproval(endsIn: 30 * 86_400, id: "model-later")
        #expect(select([pinnedLater, modelLater], facts: facts) == modelLater)
        // Facts that cannot be described choose no build-pinned entry, and leave a model approval chosen.
        #expect(select([pinnedLater, serial]) == serial)
        #expect(select([pinnedLater]) == nil)
    }

    @Test func aSavedApprovalIsKeptReplacedNearItsEndAndRemovedOnceEnded() throws {
        let m = try macs(), model = ClusterApprovalMacs.model
        let fresh = m.approval(), near = m.approval(endsIn: 3_600, id: "near"), ended = m.approval(endsIn: -60, id: "ended")
        let later = m.approval(endsIn: 13 * 86_400, id: "later")
        func decide(_ saved: ClusterRuntimeApproval?, _ fetched: ClusterApprovalFetch.Outcome) -> ClusterApprovalLifetime.Decision {
            ClusterApprovalLifetime.decide(saved: saved, fetched: fetched, model: model, schedule: .serial,
                                           artifact: m.capability.artifactSHA256, facts: { try? m.facts() }, now: now)
        }
        #expect(decide(nil, .approvals([fresh])) == .save(fresh))
        #expect(decide(nil, .notOffered) == .keep)
        #expect(decide(nil, .unavailable("no answer")) == .keep)
        // Facts that cannot be described choose no entry.
        #expect(ClusterApprovalLifetime.decide(saved: nil, fetched: .approvals([fresh]), model: model, schedule: .serial,
                                               artifact: m.capability.artifactSHA256, facts: { nil }, now: now) == .keep)
        // More than a day left and still listed: nothing is written; no usable answer says nothing about it.
        #expect(decide(fresh, .approvals([fresh, later])) == .keep)
        #expect(decide(fresh, .unavailable("HTTP 500")) == .keep)
        #expect(decide(fresh, .unreachable("no answer")) == .keep)
        // No longer listed (a 200 without it, an empty list, a 404): replaced by a matching entry, else withdrawn.
        #expect(decide(fresh, .approvals([later])) == .save(later))
        #expect(decide(fresh, .approvals([])) == .withdrawn)
        #expect(decide(fresh, .notOffered) == .withdrawn)
        // Replaced in place under the same `id` (a new `not_after`): the coordinator no longer approves the saved
        // bytes, so the listed entry is saved; a replacement this setup does not match withdraws it.
        let replaced = m.approval(endsIn: 10 * 86_400)
        #expect(replaced.id == fresh.id && replaced != fresh)
        #expect(decide(fresh, .approvals([replaced])) == .save(replaced))
        #expect(decide(fresh, .approvals([m.approval(model: "other/model", id: fresh.id)])) == .withdrawn)
        // Within a day of its end: a later one replaces it; still listed without one, it stays until it ends.
        #expect(decide(near, .approvals([near, later])) == .save(later))
        #expect(decide(near, .approvals([near])) == .keep)
        #expect(decide(near, .notOffered) == .withdrawn)
        // Ended: replaced when there is a later one, else removed (never kept).
        #expect(decide(ended, .approvals([later])) == .save(later))
        #expect(decide(ended, .notOffered) == .remove)
        #expect(decide(ended, .unavailable("no answer")) == .remove)
    }

    @Test func aSetupIsOfferedOnlyWhileItsApprovalIsCurrentAndTheClusterServesPublicly() throws {
        let m = try macs()
        let saved = try m.saved(m.leader)
        func member(_ approval: ClusterRuntimeApproval) -> ClusterNativeMemberAttachment {
            ClusterNativeMemberAttachment(ownerSHA256: ClusterApprovalMacs.hash("1"), metallibPath: "/m", resourceLibraryPath: "/r",
                clusterApproval: approval, roster: .init(generation: 1, members: []), memberPins: [], edges: nil)
        }
        #expect(saved.configuration.nativeMember == nil)
        #expect(ClusterApprovalLifetime.offers(member(m.approval()), scope: .publicServing, now: now))
        #expect(!ClusterApprovalLifetime.offers(member(m.approval(endsIn: -1)), scope: .publicServing, now: now))
        #expect(!ClusterApprovalLifetime.offers(member(m.approval()), scope: .localOnly(bind: "127.0.0.1"), now: now))
        let approval = m.approval()
        #expect(ClusterApprovalLifetime.offeredLine(member(approval))
            == "Registered with the coordinator as a cluster member: approval \(approval.id), until \(approval.notAfter)")
    }

    @Test func theScreensSayOfferedInOneLineAndTheLogLineIsRead() {
        let ready = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.this, port: 0, deployment: "Serving fixture across both Macs",
            offered: "Registered with the coordinator as a cluster member: approval a, until b")
        #expect(ready.lines(model: "fixture") == ["Serving fixture across both Macs", "Registered with the coordinator as a cluster member: approval a, until b"])
        let local = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.this, port: 8000)
        #expect(local.lines(model: "fixture") == ["Serving fixture across both Macs", "API at http://localhost:8000 on this Mac"])
        let log = "Notice: Serving locally on this Mac's API; public serving needs a coordinator with cluster support\n"
            + "darkbloom 0.10.4 (registered cluster member; solo inference disabled)\n" + ClusterLocalServing.offeredLogLine + "\n"
        #expect(ClusterLocalServing.notice(inLog: log) == ClusterLocalServing.offeredNotice)
        #expect(ClusterLocalServing.notice(inLog: log + ClusterLocalServing.logLine + "\n") == ClusterLocalServing.notice)
    }
}
