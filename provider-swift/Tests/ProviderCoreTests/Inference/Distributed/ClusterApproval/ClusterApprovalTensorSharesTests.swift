import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// A Qwen3.8 27B tensor-parallel pair and the coordinator's cluster approval, with each Mac's real configuration
/// store, pairing store and installed files (`ClusterApprovalMacs`). On two unequal Macs the plan may give the faster
/// Mac the larger share of every layer (`ClusterConfiguration.tensorShares`). A member's registration names no
/// tensor-parallel shares (`NativePairMemberRoster`), so such a setup could never register with the coordinator, and
/// it is not offered for pairing: the leader's own check refuses it, with the reason, before any part stops.
@Suite("Cluster approval and unequal tensor-parallel shares", .serialized)
struct ClusterApprovalTensorSharesTests {
    static let refusedHere = "Not offered for pairing: this Mac's check refused it: "
    static let reason = "Unequal tensor-parallel shares serve local clusters only"

    /// The roster registration a member builds from its saved setup (`ClusterMemberPreparation.nativeMemberInstallation`).
    static func registration(_ macs: ClusterApprovalMacs, _ mac: ClusterApprovalMacs.Mac) throws -> NativePairMemberRoster {
        let configuration = try macs.saved(mac).configuration
        let paired = try ClusterApprovalAttachment.pairing(configuration, store: mac.pairing)
        let profile = try ClusterRegisteredDeviceProfile(chipName: "Apple M3 Ultra", numericsClass: ClusterRosterMemberTests.classes[0],
            gpuCores: 80, memoryBytes: 256 << 30, usableWiredBytes: 200 << 30, osBuild: "25C56")
        return try NativePairMemberRoster(clusterID: configuration.clusterID, rank: configuration.localRank, roster: paired.roster,
            rankPins: paired.pins, policyBytes: try macs.approval().canonicalPolicy(), model: configuration.publicModelID,
            artifactSHA256: ClusterApprovalMacs.hash("b"), planSHA256: configuration.selectedPlanSHA256, cut: 32,
            mode: configuration.selectedGenerationMode, tensorShares: configuration.tensorShares, deviceProfile: profile, edges: [])
    }

    /// The DevNet traffic run (2026-11-04): the refusals said "press m in `darkbloom cluster`", but no item of its list
    /// starts with m, so the key did nothing. They name the step that plans the model again, in this build's command,
    /// and still reach the leader whole through the other Mac's refusal and the link's wrapping of it
    /// (`ClusterSetupLinkExchange`: "the other Mac refused: …"; `ClusterSetupFailure` keeps 240 characters).
    @Test func theRefusalsNameAStepTheScreenHas() {
        let cli = ClusterOnboardingCommand.name
        for refusal in [ClusterApprovalAttachment.unequalTensorSharesServeLocally, ClusterConfiguration.tensorAssistantServesLocally] {
            #expect(!refusal.contains("press m"), "\(refusal)")
            #expect(refusal.contains("choose the model again in `\(cli) cluster`"), "\(refusal)")
            #expect(("the other Mac refused: " + ClusterApprovalSync.peerRefusalPrefix + refusal).count <= 240, "\(refusal)")
        }
    }

    @Test func aPairPlannedWithEqualSharesIsSavedOnBothMacsAndRegisters() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider", shape: .qwen27TensorParallel(assistant: nil))
        let approval = macs.approval(), facts = try macs.facts()
        let result = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts)
        #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(approval), note: .some(nil)))
        for mac in macs.macs {
            #expect(try macs.saved(mac).configuration.nativeMember?.clusterApproval == approval, "rank \(mac.rank) saved no approval")
            #expect(try Self.registration(macs, mac).plan.mode == ClusterGenerationMode.tensorParallel.rawValue, "rank \(mac.rank)")
        }
    }

    /// Before: both Macs saved the approval and said "offered", and then neither member could build its registration
    /// (`ClusterRosterError.invalidPlan`), so the coordinator never formed the pair and routed it nothing.
    @Test func aPairWithUnequalSharesIsNotOfferedBecauseItCouldNeverRegister() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider",
                                           shape: .qwen27TensorParallel(assistant: nil, shares: [2, 1]))
        for mac in macs.macs {
            #expect(try macs.saved(mac).configuration.tensorShares == [2, 1], "rank \(mac.rank)")
            #expect(throws: ClusterRosterError.invalidPlan) { try Self.registration(macs, mac) }
        }
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
        #expect(!checked.changed && checked.line?.hasPrefix(Self.refusedHere + Self.reason) == true, "\(checked.line ?? "")")
        #expect(checked.note == .some(checked.line))
        #expect(try macs.macs.map(macs.bytes) == before)
        // The registration after the guided setup's Test stage (`OnboardingLive.localRegister`, `run`): refused here
        // too, so nothing reaches the other Mac and neither Mac says the pair is offered.
        let registered = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts, sent: sent)
        #expect(!registered.changed && sent.values.isEmpty, "sent \(sent.values.map(\.op))")
        #expect(registered.line?.hasPrefix(Self.refusedHere + Self.reason) == true, "\(registered.line ?? "")")
        #expect(registered.line != ClusterApprovalLifetime.offeredLine(approval))
        #expect(try macs.macs.map(macs.bytes) == before)
        for mac in macs.macs { #expect(try macs.saved(mac).configuration.nativeMember == nil, "rank \(mac.rank)") }
    }

    /// The other Mac checks the same rule before it saves anything, so a leader of an earlier build that sends the
    /// approval anyway gets the reason in plain words, and the other Mac's setup stays as it was.
    @Test func theOtherMacRefusesAnUnequalShareSetupWithThePlainReason() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider",
                                           shape: .qwen27TensorParallel(assistant: nil, shares: [1, 2]))
        let before = try macs.bytes(macs.follower)
        var command = ClusterServiceCommand(op: .approval)
        command.approval = macs.approval()
        command.approvalEdge = ClusterEdge(peerPin: macs.leader.pin, transport: "rdma", measuredMbps: 1, measuredRTTMicros: 1)
        let refused = #expect(throws: (any Error).self) { try macs.cable(facts: try macs.facts())(command) }
        let reason = refused.map(ClusterApprovalSync.refusal) ?? ""
        #expect(reason.contains(ClusterApprovalSync.peerRefusalPrefix + Self.reason), "\(reason)")
        #expect(try macs.bytes(macs.follower) == before)
    }
}
