import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// A Qwen3.8 27B tensor-parallel pair and the coordinator's cluster approval, with each Mac's real configuration
/// store, pairing store and installed files (`ClusterApprovalMacs`). The model's embedded speculative assistant
/// (`ClusterConfiguration.tensorAssistant`) has no public qualification and serves local clusters only, so a setup
/// saved for coordinator pairing carries none: a pair planned without it is saved on both Macs, and a setup with it is
/// refused by the leader's own check, before any part stops and before anything reaches the other Mac.
@Suite("Cluster approval and the Qwen tensor assistant", .serialized)
struct ClusterApprovalTensorAssistantTests {
    static func assistant() throws -> ClusterQwenTensorAssistantPolicy {
        try ClusterQwenTensorAssistantPolicy(depth: 3, inventorySHA256: ClusterApprovalMacs.hash("8"), verification: .admittedCohort)
    }

    static let refusedHere = "Not offered for pairing: this Mac's check refused it: "

    @Test func aQwenTensorParallelPairWithoutTheAssistantIsSavedOnBothMacs() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider", shape: .qwen27TensorParallel(assistant: nil))
        let approval = macs.approval(), facts = try macs.facts()
        let result = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts)
        #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(approval), note: .some(nil)))
        for mac in macs.macs {
            let saved = try macs.saved(mac).configuration
            #expect(saved.nativeMember?.clusterApproval == approval, "rank \(mac.rank) saved no approval")
            #expect(saved.selectedGenerationMode == .tensorParallel && saved.tensorAssistant == nil, "rank \(mac.rank)")
        }
    }

    @Test func theLeaderRefusesATensorAssistantSetupBeforeAnyPartStops() throws {
        let policy = try Self.assistant()
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider", shape: .qwen27TensorParallel(assistant: policy))
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.tensorAssistant == policy, "rank \(mac.rank)") }
        let approval = macs.approval(), facts = try macs.facts(), before = try macs.macs.map(macs.bytes)
        let sent = ClusterApprovalRecorder<ClusterServiceCommand>()
        var stops = 0, serves = 0
        // The control leader's minute check (`ClusterService.checkApproval`): no part stops, nothing is sent to the
        // other Mac, nothing starts again, and the reason is the status note.
        let checked = ClusterApprovalSync.apply(.save(approval), grace: 600, paths: macs.leader.paths,
            providerConfiguration: macs.leader.provider, pairingStore: macs.leader.pairing, scratch: macs.leader.scratch,
            now: Date().timeIntervalSince1970, stop: { stops += 1; return nil }, serve: { serves += 1 },
            sendToPeer: macs.cable(facts: facts, sent: sent), chipClass: ClusterApprovalMacs.chip, facts: { _ in facts })
        #expect(stops == 0 && serves == 0 && sent.values.isEmpty, "stops \(stops), serves \(serves), sent \(sent.values.map(\.op))")
        #expect(!checked.changed && checked.line?.hasPrefix(Self.refusedHere) == true, "\(checked.line ?? "")")
        #expect(checked.line == Self.refusedHere + ClusterConfiguration.tensorAssistantServesLocally)
        #expect(checked.note == .some(checked.line))
        #expect(try macs.macs.map(macs.bytes) == before)
        // The registration after the guided setup's Test stage (`OnboardingLive.localRegister`, `run`): this Mac's own
        // check refuses it too, so nothing reaches the other Mac.
        let registered = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts, sent: sent)
        #expect(!registered.changed && sent.values.isEmpty, "sent \(sent.values.map(\.op))")
        #expect(registered.line?.hasPrefix(Self.refusedHere) == true, "\(registered.line ?? "")")
        #expect(try macs.macs.map(macs.bytes) == before)
    }

    /// The other Mac checks the same rule itself before it saves anything, so a leader of an earlier build that sends
    /// the approval anyway gets the reason in plain words, and the other Mac's setup stays as it was.
    @Test func theOtherMacRefusesATensorAssistantSetupWithThePlainReason() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider",
                                           shape: .qwen27TensorParallel(assistant: try Self.assistant()))
        let before = try macs.bytes(macs.follower)
        var command = ClusterServiceCommand(op: .approval)
        command.approval = macs.approval()
        command.approvalEdge = ClusterEdge(peerPin: macs.leader.pin, transport: "rdma", measuredMbps: 1, measuredRTTMicros: 1)
        let refused = #expect(throws: (any Error).self) { try macs.cable(facts: try macs.facts())(command) }
        let reason = refused.map(ClusterApprovalSync.refusal) ?? ""
        #expect(reason.hasSuffix(ClusterApprovalSync.peerRefusalPrefix + ClusterConfiguration.tensorAssistantServesLocally), "\(reason)")
        #expect(try macs.bytes(macs.follower) == before)
        // The same setup without an approval (the leader serving locally) is saved as it is: nothing to refuse.
        try macs.cable(facts: try macs.facts())(ClusterServiceCommand(op: .approval))
        #expect(try macs.bytes(macs.follower) == before)
    }
}
