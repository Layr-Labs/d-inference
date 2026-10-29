import Foundation
import Testing
@testable import ProviderCore

/// The actual cluster service loop on the leading Mac of a pair whose setup carries a cluster approval. Its parts are
/// the CPU-only service-part fixture process (one role per route), so the route the service chose is the role that
/// started. Nothing here loads a model.
@Suite("Cluster approval at a service start", .serialized)
struct ClusterApprovalServiceStartTests {
    /// The leader's setup saved with an approval ending `endsIn` seconds from now (in the past: ended): a cluster
    /// approval as the guided setup saves it, or (`handSaved`) a pair approval an operator saved by hand.
    private func setUp(endsIn: Double, handSaved: Bool = false) throws -> (ClusterApprovalMacs, ClusterService, URL) {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let leader = macs.leader, saved = try macs.saved(leader), facts = try macs.facts()
        let current = try ClusterApprovalAttachment.attachment(for: macs.approval(), saved: saved, paths: leader.paths,
            pairingStore: leader.pairing, edge: nil, now: Date().timeIntervalSince1970, chipClass: ClusterApprovalMacs.chip,
            facts: { _ in facts })
        let attachment: ClusterNativeMemberAttachment
        if handSaved {
            let h = ClusterApprovalMacs.hash
            let end = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + endsIn).rounded(.down)))
            let pair = try ClusterPairApprovalTests.approval(["id": "hand-saved", "model": ClusterApprovalMacs.model, "generation": 1,
                "plan_sha256": h("f"), "artifact_sha256": h("b"), "native_runtime_sha256": h("a"),
                "metallib_sha256": h("3"), "resource_library_sha256": h("4"), "capability_sha256": macs.capabilitySHA256,
                "resource_policy_sha256": h("8"), "profile_sha256": h("e"), "schedule": 1,
                "maximum_transport_frame": 131_112, "maximum_plaintext": 131_072, "maximum_records": 1024,
                "maximum_cumulative_plaintext": 16_777_216, "allowed_chips": ["Apple M3 Ultra"], "not_after": end])
            attachment = ClusterNativeMemberAttachment(ownerSHA256: current.ownerSHA256, metallibPath: current.metallibPath,
                resourceLibraryPath: current.resourceLibraryPath, approval: pair)
        } else {
            attachment = ClusterNativeMemberAttachment(ownerSHA256: current.ownerSHA256, metallibPath: current.metallibPath,
                resourceLibraryPath: current.resourceLibraryPath, clusterApproval: macs.approval(endsIn: endsIn),
                roster: try #require(current.roster), memberPins: try #require(current.memberPins), edges: nil)
        }
        try ClusterApprovalAttachment.save(attachment, saved: saved, paths: leader.paths, providerConfiguration: leader.provider,
                                           scratch: leader.scratch)
        // The loop answers no paired Mac here: only its own part is under test.
        try FileManager.default.moveItem(at: leader.pairing.directory,
                                         to: leader.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
        let helper = leader.home.appendingPathComponent("service-part-fixture")
        try NativePairMemberFixture.helper().write(to: helper, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let parts = leader.home.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: leader.provider, darkbloomExecutable: helper,
            sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
        let service = ClusterService(settings: .init(wizard: wizard,
            leaderArguments: ["--service-part-fixture", parts.path, "leader"], followerArguments: [],
            soloArguments: ["--service-part-fixture", parts.path, "replacement"],
            memberArguments: ["--service-part-fixture", parts.path, "member"]), paths: leader.paths, recoveryGraceSeconds: 0.2)
        var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: leader.pin, peerPin: macs.follower.pin,
            peerName: "fixture peer", since: "fixture")
        leadership.serving = true; leadership.modelName = ClusterApprovalMacs.model
        _ = try service.store.updateRecord { $0.leadership = leadership }
        // A real control node inside the absence grace of the other Mac: this Mac runs its part of the cluster.
        let local = leader.memberID, peer = macs.follower.memberID
        let node = ClusterControlNode(localID: local,
            members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1, holdsModelAlone: false)],
            claim: .init(term: 1, leaderID: local, members: [local, peer], reason: "fixture"),
            rankOrder: [local, peer], now: ClusterService.monotonicSeconds(), ttl: 1, soloGrace: 3_600)
        service.lock.withLock { service.control = node }
        return (macs, service, parts)
    }

    private func started(_ parts: URL, _ role: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? []).contains { $0.hasPrefix(role + "-") && $0.hasSuffix(".ready") }
    }

    private func run(_ service: ClusterService, parts: URL, until predicate: () -> Bool) -> (Bool, [String]) {
        let stop = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let lines = ClusterApprovalRecorder<String>()
        Thread.detachNewThread {
            _ = try? service.run(stop: stop) { lines.append($0) }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(20)
        var reached = predicate()
        while !reached, Date() < deadline { usleep(20_000); reached = predicate() }
        for role in ["leader", "member", "replacement"] {
            try? Data().write(to: parts.appendingPathComponent("release-\(role)"))
        }
        stop.signal()
        #expect(done.wait(timeout: .now() + 30) == .success, "the service did not stop")
        return (reached, lines.values)
    }

    @Test func aStartWithAnEndedApprovalServesOnTheLeadersLocalAPI() throws {
        let (macs, service, parts) = try setUp(endsIn: -60)
        let (reached, lines) = run(service, parts: parts) { started(parts, "leader") }
        #expect(reached, "the part that serves locally did not start: \(lines)")
        #expect(!started(parts, "member"), "an ended approval was offered to the coordinator")
        #expect(try macs.saved(macs.leader).configuration.nativeMember == nil, "the ended approval stayed saved")
        #expect(lines.contains { $0.contains("expired: saved this Mac's setup without it") }, "\(lines)")
    }

    @Test func aStartWithACurrentApprovalRunsTheCoordinatorFormedMember() throws {
        let (macs, service, parts) = try setUp(endsIn: 14 * 86_400)
        let before = try macs.bytes(macs.leader)
        let (reached, lines) = run(service, parts: parts) { started(parts, "member") }
        #expect(reached, "the member part did not start: \(lines)")
        #expect(!started(parts, "leader"))
        #expect(try macs.bytes(macs.leader) == before, "a current approval was rewritten")
    }

    @Test func aHandSavedPairApprovalThatEndedStaysSavedAndIsNeverOffered() throws {
        let (macs, service, parts) = try setUp(endsIn: -60, handSaved: true)
        let before = try macs.bytes(macs.leader)
        // The ordinary part starts (and, on a real Mac, says why it cannot run beside the saved approval).
        let (reached, lines) = run(service, parts: parts) { started(parts, "leader") }
        #expect(reached, "the ordinary part did not start: \(lines)")
        #expect(!started(parts, "member"), "an ended pair approval was offered to the coordinator")
        #expect(try macs.bytes(macs.leader) == before, "the operator's pair approval was removed")
        #expect(try macs.saved(macs.leader).configuration.nativeMember?.approval?.id == "hand-saved")
    }
}
