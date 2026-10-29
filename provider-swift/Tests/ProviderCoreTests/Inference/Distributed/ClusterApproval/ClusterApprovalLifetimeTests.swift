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
            ClusterApprovalLifetime.select(approvals, model: ClusterApprovalMacs.model, schedule: schedule, facts: facts, now: now)
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

    @Test func aSavedApprovalIsKeptReplacedNearItsEndAndRemovedOnceEnded() throws {
        let m = try macs(), model = ClusterApprovalMacs.model
        let fresh = m.approval(), near = m.approval(endsIn: 3_600, id: "near"), ended = m.approval(endsIn: -60, id: "ended")
        let later = m.approval(endsIn: 13 * 86_400, id: "later")
        func decide(_ saved: ClusterRuntimeApproval?, _ fetched: ClusterApprovalFetch.Outcome) -> ClusterApprovalLifetime.Decision {
            ClusterApprovalLifetime.decide(saved: saved, fetched: fetched, model: model, schedule: .serial,
                                           facts: { try? m.facts() }, now: now)
        }
        #expect(decide(nil, .approvals([fresh])) == .save(fresh))
        #expect(decide(nil, .notOffered) == .keep)
        #expect(decide(nil, .unavailable("no answer")) == .keep)
        // Facts that cannot be described choose no entry.
        #expect(ClusterApprovalLifetime.decide(saved: nil, fetched: .approvals([fresh]), model: model, schedule: .serial,
                                               facts: { nil }, now: now) == .keep)
        // More than a day left and still listed: nothing is written; no usable answer says nothing about it.
        #expect(decide(fresh, .approvals([fresh, later])) == .keep)
        #expect(decide(fresh, .unavailable("HTTP 500")) == .keep)
        #expect(decide(fresh, .unreachable("no answer")) == .keep)
        // No longer listed (a 200 without it, an empty list, a 404): replaced by a matching entry, else withdrawn.
        #expect(decide(fresh, .approvals([later])) == .save(later))
        #expect(decide(fresh, .approvals([])) == .withdrawn)
        #expect(decide(fresh, .notOffered) == .withdrawn)
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
            == "Offered to the coordinator for pairing: approval \(approval.id), until \(approval.notAfter)")
    }

    @Test func theScreensSayOfferedInOneLineAndTheLogLineIsRead() {
        let ready = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.this, port: 0, deployment: "Serving fixture across both Macs",
            offered: "Offered to the coordinator for pairing: approval a, until b")
        #expect(ready.lines(model: "fixture") == ["Serving fixture across both Macs", "Offered to the coordinator for pairing: approval a, until b"])
        let local = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.this, port: 8000)
        #expect(local.lines(model: "fixture") == ["Serving fixture across both Macs", "API at http://localhost:8000 on this Mac"])
        let log = "Notice: Serving locally on this Mac's API; public serving needs a coordinator with cluster support\n"
            + "darkbloom 0.10.4 (registered cluster member; solo inference disabled)\n" + ClusterLocalServing.offeredLogLine + "\n"
        #expect(ClusterLocalServing.notice(inLog: log) == ClusterLocalServing.offeredNotice)
        #expect(ClusterLocalServing.notice(inLog: log + ClusterLocalServing.logLine + "\n") == ClusterLocalServing.notice)
    }
}
