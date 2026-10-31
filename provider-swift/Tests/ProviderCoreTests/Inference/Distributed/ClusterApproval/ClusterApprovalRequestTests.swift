import Foundation
import Testing
@testable import ProviderCore

/// `POST /v1/cluster/approvals` against a real local HTTP server that answers as the coordinator does: what the
/// leader sends, with which credential, and that every answer but 200 or 201 is one line that stops nothing.
@Suite("Cluster approval request", .serialized)
struct ClusterApprovalRequestTests {
    private func coordinator() async throws -> (MockCoordinator, String) {
        let mock = MockCoordinator()
        let base = try await mock.start()
        return (mock, base.mockProviderWebSocketURL())
    }

    private func answer(_ approval: ClusterRuntimeApproval) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["approval": try JSONSerialization.jsonObject(with: JSONEncoder().encode(approval))])
    }

    private func installApp(_ mac: ClusterApprovalMacs.Mac, version: String) throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version],
                                                       format: .xml, options: 0)
        try plist.write(to: mac.home.appendingPathComponent("app/Contents/Info.plist"))
    }

    @Test func theLeaderSendsTheInstalledVersionModelAndScheduleWithItsCredential() async throws {
        let (mock, url) = try await coordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        try installApp(macs.leader, version: "0.10.5-dev.branch.42")
        let approval = macs.modelApproval(id: "owner/acct/fixture/qwen/s1/0123456789ab")
        mock.setClusterApprovalRequests(status: 201, body: try answer(approval))
        let outcome = await ClusterApprovalRequest.request(for: try macs.saved(macs.leader).configuration,
                                                           providerConfiguration: macs.leader.provider, token: "account-token")
        #expect(outcome == .registered("owner/acct/fixture/qwen/s1/0123456789ab"))
        #expect(outcome.line == "Cluster approval request: the coordinator holds approval owner/acct/fixture/qwen/s1/0123456789ab for this pair.")
        let sent = mock.snapshot()
        #expect(sent.clusterApprovalAuthorizations == ["Bearer account-token"])
        let body = try #require(sent.clusterApprovalPosts.first)
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"model":"fixture/qwen","provider_version":"0.10.5-dev.branch.42","schedule":1}"#)
        await mock.shutdown()
    }

    @Test func anExistingLiveRowIsTakenAsRegistered() async throws {
        let (mock, url) = try await coordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        mock.setClusterApprovalRequests(status: 200, body: try answer(macs.modelApproval()))
        #expect(await ClusterApprovalRequest.request(coordinatorURL: url, token: "t", providerVersion: "0.10.5-dev.1",
                                                     model: ClusterApprovalMacs.model, schedule: 2)
            == .registered("devnet/fixture/qwen/s1"))
        // An answer without a readable approval still says the coordinator took it; the fetch decides what is saved.
        mock.setClusterApprovalRequests(status: 201, body: Data("created".utf8))
        let outcome = await ClusterApprovalRequest.request(coordinatorURL: url, token: "t", providerVersion: "0.10.5-dev.1",
                                                           model: ClusterApprovalMacs.model, schedule: 2)
        #expect(outcome == .registered(nil))
        #expect(outcome.line == "Cluster approval request: the coordinator took it.")
        #expect(mock.snapshot().clusterApprovalPosts.count == 2)
        await mock.shutdown()
    }

    @Test func productionStagingAndASettingOffAreNotTaken() async throws {
        let (mock, url) = try await coordinator()
        func ask() async -> ClusterApprovalRequest.Outcome {
            await ClusterApprovalRequest.request(coordinatorURL: url, token: "t", providerVersion: "0.10.5",
                                                 model: ClusterApprovalMacs.model, schedule: 1)
        }
        // No route at all (a coordinator without owner approvals) is a 404.
        #expect(await ask() == .notTaken(404))
        mock.setClusterApprovalRequests(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8))
        let refused = await ask()
        #expect(refused == .notTaken(403))
        #expect(refused.line == "Cluster approval request: not taken by this coordinator (HTTP 403).")
        await mock.shutdown()
    }

    @Test func everyOtherAnswerFailsInOneLine() async throws {
        let (mock, url) = try await coordinator()
        for (status, location) in [(409, nil), (400, nil), (500, nil), (302, "https://elsewhere.invalid/v1/cluster/approvals")] as [(Int, String?)] {
            mock.setClusterApprovalRequests(status: status, body: Data("{}".utf8), location: location)
            let outcome = await ClusterApprovalRequest.request(coordinatorURL: url, token: "t", providerVersion: "0.10.5-dev.1",
                                                               model: ClusterApprovalMacs.model, schedule: 1)
            #expect(outcome == .failed("HTTP \(status)"))
            #expect(outcome.line == "Cluster approval request: failed (HTTP \(status)).")
        }
        // The redirect was not followed: only this server's route saw requests.
        #expect(mock.snapshot().clusterApprovalPosts.count == 4)
        await mock.shutdown()
    }

    @Test func nothingIsSentWithoutACredentialAVersionOrAnHTTPSCoordinator() async throws {
        let (mock, url) = try await coordinator()
        mock.setClusterApprovalRequests(status: 201, body: Data("{}".utf8))
        for token in [nil, ""] as [String?] {
            #expect(await ClusterApprovalRequest.request(coordinatorURL: url, token: token, providerVersion: "0.10.5-dev.1",
                                                         model: ClusterApprovalMacs.model, schedule: 1)
                == .failed("this Mac is not linked to an account"))
        }
        #expect(await ClusterApprovalRequest.request(coordinatorURL: "ws://coordinator.example/ws/provider", token: "t",
                                                     providerVersion: "0.10.5-dev.1", model: ClusterApprovalMacs.model, schedule: 1)
            == .failed("the coordinator URL is not HTTPS"))
        // No Info.plist beside the setup's helpers: no version, so no request.
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        #expect(await ClusterApprovalRequest.request(for: try macs.saved(macs.leader).configuration,
                                                     providerConfiguration: macs.leader.provider, token: "t")
            == .failed("the installed app's version could not be read"))
        // A provider configuration that cannot be read (here a folder) names no coordinator.
        #expect(await ClusterApprovalRequest.request(for: try macs.saved(macs.leader).configuration,
                                                     providerConfiguration: macs.root, token: "t")
            == .failed("the provider configuration names no coordinator"))
        #expect(mock.snapshot().clusterApprovalPosts.isEmpty)
        await mock.shutdown()
    }

    @Test func noAnswerFailsInOneLine() async throws {
        // Nothing listens on port 9 of this Mac.
        let outcome = await ClusterApprovalRequest.request(coordinatorURL: "ws://127.0.0.1:9/ws/provider", token: "t",
                                                           providerVersion: "0.10.5-dev.1", model: ClusterApprovalMacs.model, schedule: 1)
        guard case .failed(let reason) = outcome else { Issue.record("no answer was \(outcome)"); return }
        #expect(reason.hasPrefix("no answer: "), "\(reason)")
    }
}
