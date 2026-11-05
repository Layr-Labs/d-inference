import Foundation
import Testing
@testable import ProviderCore

/// 0.10.9 DevNet f1: the leader's part started and ended every 38 s while the other Mac's single-Mac provider held that
/// Mac's part back. The leader reads why from the other Mac's status and waits.
@Suite("The leader waits while the other Mac's part is held back")
struct SoloBlockPeerTests {
    private func status(_ json: String) throws -> ClusterServiceStatus {
        try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(json.utf8))
    }

    @Test("the other Mac's single-Mac serving is a reason to wait; none, or an older build, is not")
    func heldBackFromStatus() throws {
        let base = #""serving":true,"sessionLeader":false,"child":{"running":false,"starts":0}"#
        let older = try status("{\(base)}")
        #expect(ClusterService.heldBack(of: older) == nil)
        let solo = try status("{\(base),\"soloServing\":{\"pid\":68099}}")
        #expect(ClusterService.heldBack(of: solo) == "a single-Mac Darkbloom provider (process 68099) is serving there")
        let said = try status("{\(base),\"soloServing\":{\"pid\":68099},\"heldBack\":\"its own words\"}")
        #expect(ClusterService.heldBack(of: said) == "its own words")
    }

    @Test("the leader's part waits for it, and starts again once it clears; serving alone never waits")
    func leaderPartWaits() throws {
        let base = #""serving":true,"sessionLeader":false,"child":{"running":false,"starts":0}"#
        let member = try status("{\(base),\"soloServing\":{\"pid\":68099}}")
        let held = ClusterService.heldBack(of: member)
        #expect(ClusterControlPartChoice.waitsForOtherMac(key: "cluster:84377e741989", otherMacHeldBack: held, leads: true) != nil)
        #expect(ClusterControlPartChoice.waitsForOtherMac(key: "cluster:84377e741989", otherMacHeldBack: held, leads: false) == nil)
        #expect(ClusterControlPartChoice.waitsForOtherMac(key: "cluster:84377e741989",
            otherMacHeldBack: ClusterService.heldBack(of: try status("{\(base)}")), leads: true) == nil)
        #expect(ClusterControlPartChoice.waitsForOtherMac(key: "solo:EigenLabs/Qwen3.8-27B-4bit-mtp", otherMacHeldBack: held, leads: true) == nil)
    }
}
