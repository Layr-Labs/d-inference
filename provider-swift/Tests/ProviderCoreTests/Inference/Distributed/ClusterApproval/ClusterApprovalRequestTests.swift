import Foundation
import Testing
@testable import ProviderCore

/// The owner approvals (`/v1/cluster/owner-approvals`) against a real local HTTP server that answers as the
/// coordinator does, and against the vector the coordinator's tests pin with the same bytes: what the leader sends,
/// with which credential, when it asks or renews, that every answer but a verified 200 or 201 is one line that stops
/// nothing, and that the account's own approvals join the public list only as a whole answer.
@Suite("Cluster approval request", .serialized)
struct ClusterApprovalRequestTests {
    static let ownID = "owner/acct/fixture/qwen/s1/0123456789ab"

    private func coordinator() async throws -> (MockCoordinator, String) {
        let mock = MockCoordinator()
        let base = try await mock.start()
        return (mock, base.mockProviderWebSocketURL())
    }

    /// The shared vector: `Fixtures/coordinator-wire/owner_cluster_approval_vector.json`, byte for byte the coordinator's
    /// `coordinator/tests/api/testdata/owner_cluster_approval_vector.json`.
    private func vector() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "owner_cluster_approval_vector", withExtension: "json",
                                                 subdirectory: "Fixtures/coordinator-wire"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func entry(_ approval: ClusterRuntimeApproval, policy: String? = nil) throws -> [String: Any] {
        let derived = ClusterConfigurationCodec.sha256(try approval.canonicalPolicy())
        return ["approval": try JSONSerialization.jsonObject(with: JSONEncoder().encode(approval)), "policy_sha256": policy ?? derived]
    }

    private func owned(_ approvals: [ClusterRuntimeApproval]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["approvals": try approvals.map { try entry($0) }])
    }

    private func reply(_ approval: ClusterRuntimeApproval) throws -> Data {
        try JSONSerialization.data(withJSONObject: try entry(approval))
    }

    private func installApp(_ mac: ClusterApprovalMacs.Mac, version: String) throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version],
                                                       format: .xml, options: 0)
        try plist.write(to: mac.home.appendingPathComponent("app/Contents/Info.plist"))
    }

    private func ask(_ url: String, token: String? = "t") async -> ClusterApprovalRequest.Outcome {
        await ClusterApprovalRequest.request(coordinatorURL: url, token: token, providerVersion: "0.10.5-dev.branch.16",
                                             model: "glm-5.3-flash", artifact: String(repeating: "3a", count: 32), schedule: 1)
    }

    // MARK: - The shared vector

    @Test func theProviderSendsAndReadsTheSharedVectorByteForByte() async throws {
        let vector = try vector()
        #expect(vector["method"] as? String == "POST")
        #expect(vector["path"] as? String == ClusterApprovalRequest.path)
        let request = try #require(vector["request"] as? String), response = try #require(vector["response"] as? String)
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let version = try #require(fields["provider_version"] as? String), model = try #require(fields["model"] as? String)
        let artifact = try #require(fields["artifact_sha256"] as? String), schedule = try #require(fields["schedule"] as? Int)
        #expect(try ClusterApprovalRequest.body(providerVersion: version, model: model, artifact: artifact, schedule: UInt8(schedule))
            == Data(request.utf8))
        // The reply: one owner approval whose canonical bytes and policy_sha256 are the vector's.
        let approval = try ClusterApprovalFetch.decodeOwnedEntry(Data(response.utf8))
        #expect(approval.id == "owner/account-one/glm-5.3-flash/s1/0123456789ab")
        #expect(approval.isModelApproval && approval.minimumMembers == 2 && approval.maximumMembers == 2)
        let canonical = try approval.canonicalPolicy()
        #expect(canonical.map { String(format: "%02x", $0) }.joined() == vector["canonical_hex"] as? String)
        #expect(ClusterConfigurationCodec.sha256(canonical) == "1683c2acd7e89589957a99707e85801a903e328b566cdc1e8185761599d0b148")

        // Over HTTP: the same bytes leave the provider, with its credential, and the vector's reply registers.
        let (mock, url) = try await coordinator()
        mock.setClusterApprovalRequests(status: try #require(vector["status"] as? Int), body: Data(response.utf8))
        #expect(await ClusterApprovalRequest.request(coordinatorURL: url, token: "provider-token", providerVersion: version,
                                                     model: model, artifact: artifact, schedule: UInt8(schedule))
            == .registered(approval.id))
        let sent = mock.snapshot()
        #expect(sent.clusterApprovalPosts == [Data(request.utf8)])
        #expect(sent.clusterApprovalAuthorizations == ["Bearer provider-token"])
        await mock.shutdown()
    }

    // MARK: - The request

    @Test func aSetupWithoutAnApprovalAsksWithItsInstalledVersionModelArtifactAndSchedule() async throws {
        let (mock, url) = try await coordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        try installApp(macs.leader, version: "0.10.5-dev.branch.42")
        mock.setClusterApprovalRequests(status: 201, body: try reply(macs.modelApproval(id: Self.ownID)))
        let saved = try macs.saved(macs.leader)
        #expect(ClusterApprovalRequest.need(saved, now: Date().timeIntervalSince1970) == .request)
        let outcome = await ClusterApprovalRequest.ensure(saved, providerConfiguration: macs.leader.provider,
                                                          now: Date().timeIntervalSince1970, token: "account-token")
        #expect(outcome == .registered(Self.ownID))
        #expect(outcome?.line == "Cluster approval request: the coordinator holds approval \(Self.ownID) for this pair.")
        let sent = mock.snapshot()
        #expect(sent.clusterApprovalAuthorizations == ["Bearer account-token"])
        #expect(sent.clusterApprovalPosts.map { String(decoding: $0, as: UTF8.self) } == [#"{"provider_version":"0.10.5-dev.branch.42","model":"fixture/qwen","artifact_sha256":""#
            + ClusterApprovalMacs.hash("b") + #"","schedule":1}"#])
        await mock.shutdown()
    }

    @Test func anOwnerApprovalNearItsEndIsDeletedThenAskedForAgain() async throws {
        let (mock, url) = try await coordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        try installApp(macs.leader, version: "0.10.5-dev.branch.42")
        let facts = try macs.facts()
        #expect(macs.sync(.approvals([macs.modelApproval(endsIn: 3 * 86_400, id: Self.ownID)]), leaderFacts: facts, followerFacts: facts).changed)
        let saved = try macs.saved(macs.leader), now = Date().timeIntervalSince1970
        #expect(ClusterApprovalRequest.need(saved, now: now) == .renew(Self.ownID))
        // More than a week left, or an operator's approval: nothing to ask, nothing sent.
        #expect(ClusterApprovalRequest.need(saved, now: now - 5 * 86_400) == .nothing)
        let renewed = macs.modelApproval(endsIn: 90 * 86_400, id: "owner/acct/fixture/qwen/s1/ba9876543210")
        mock.setClusterApprovalRequests(status: 201, body: try reply(renewed))
        #expect(await ClusterApprovalRequest.ensure(saved, providerConfiguration: macs.leader.provider, now: now, token: "t")
            == .registered(renewed.id))
        #expect(mock.snapshot().ownerApprovalDeletes == [Self.ownID])
        #expect(mock.snapshot().clusterApprovalPosts.count == 1)
        // A delete the coordinator refuses stops the renewal before the request; one it no longer holds does not.
        mock.setOwnerApprovalDeleteStatus(500)
        #expect(await ClusterApprovalRequest.ensure(saved, providerConfiguration: macs.leader.provider, now: now, token: "t")
            == .failed("the renewal could not delete approval \(Self.ownID): HTTP 500"))
        #expect(mock.snapshot().clusterApprovalPosts.count == 1)
        mock.setOwnerApprovalDeleteStatus(404)
        #expect(await ClusterApprovalRequest.ensure(saved, providerConfiguration: macs.leader.provider, now: now, token: "t")
            == .registered(renewed.id))
        await mock.shutdown()
    }

    @Test func anOperatorsApprovalIsNeverRenewedHere() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let facts = try macs.facts()
        #expect(macs.sync(.approvals([macs.modelApproval(endsIn: 3 * 86_400)]), leaderFacts: facts, followerFacts: facts).changed)
        #expect(ClusterApprovalRequest.need(try macs.saved(macs.leader), now: Date().timeIntervalSince1970) == .nothing)
    }

    @Test func productionStagingAndASettingOffAreNotTaken() async throws {
        let (mock, url) = try await coordinator()
        // No route at all (a coordinator without owner approvals) is a 404.
        #expect(await ask(url) == .notTaken(404))
        mock.setClusterApprovalRequests(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8))
        let refused = await ask(url)
        #expect(refused == .notTaken(403))
        #expect(refused.line == "Cluster approval request: not taken by this coordinator (HTTP 403).")
        #expect(!refused.retries)
        await mock.shutdown()
    }

    @Test func everyOtherAnswerIsOneLine() async throws {
        let (mock, url) = try await coordinator()
        let cases: [(Int, String?, Data, ClusterApprovalRequest.Outcome, Bool)] = [
            (409, nil, Data("{}".utf8), .refused(409), false),
            (500, nil, Data("{}".utf8), .failed("HTTP 500"), true),
            (302, "https://elsewhere.invalid/v1/cluster/owner-approvals", Data(), .failed("HTTP 302"), true),
            (201, nil, Data("created".utf8), .failed("the answer is not an owner approval"), true),
        ]
        for (status, location, body, expected, retries) in cases {
            mock.setClusterApprovalRequests(status: status, body: body, location: location)
            let outcome = await ask(url)
            #expect(outcome == expected, "HTTP \(status)")
            #expect(outcome.retries == retries, "HTTP \(status)")
        }
        // The redirect was not followed: only this server's route saw requests.
        #expect(mock.snapshot().clusterApprovalPosts.count == cases.count)
        // A body the coordinator does not read is its 400.
        mock.setClusterApprovalRequests(status: 201, body: Data("{}".utf8))
        let invalid = await ClusterApprovalRequest.request(coordinatorURL: url, token: "t", providerVersion: "0.10.5-dev.branch.1",
                                                           model: "glm-5.3-flash", artifact: "ABC", schedule: 1)
        #expect(invalid == .refused(400))
        #expect(invalid.line == "Cluster approval request: refused by the coordinator (HTTP 400).")
        await mock.shutdown()
    }

    @Test func nothingIsSentWithoutACredentialAVersionOrAnHTTPSCoordinator() async throws {
        let (mock, url) = try await coordinator()
        mock.setClusterApprovalRequests(status: 201, body: Data("{}".utf8))
        for token in [nil, ""] as [String?] {
            let outcome = await ask(url, token: token)
            #expect(outcome == .notSent("this Mac is not linked to an account"))
            #expect(outcome.line == "Cluster approval request: not sent (this Mac is not linked to an account).")
        }
        #expect(await ask("ws://coordinator.example/ws/provider") == .notSent("the coordinator URL is not HTTPS"))
        // No Info.plist beside the setup's helpers: no version, so no request.
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        let saved = try macs.saved(macs.leader), now = Date().timeIntervalSince1970
        #expect(await ClusterApprovalRequest.ensure(saved, providerConfiguration: macs.leader.provider, now: now, token: "t")
            == .notSent("the installed app's version could not be read"))
        // A provider configuration that cannot be read (here a folder) names no coordinator.
        #expect(await ClusterApprovalRequest.ensure(saved, providerConfiguration: macs.root, now: now, token: "t")
            == .notSent("the provider configuration names no coordinator"))
        #expect(mock.snapshot().clusterApprovalPosts.isEmpty)
        await mock.shutdown()
    }

    @Test func noAnswerFailsInOneLine() async throws {
        // Nothing listens on port 9 of this Mac.
        guard case .failed(let reason) = await ask("ws://127.0.0.1:9/ws/provider") else {
            Issue.record("no answer was not a failure"); return
        }
        #expect(reason.hasPrefix("no answer: "), "\(reason)")
    }

    // MARK: - The account's own approvals

    @Test func theAccountsOwnApprovalsJoinThePublicList() async throws {
        let (mock, url) = try await coordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        let operatorRow = macs.approval(), own = macs.modelApproval(id: Self.ownID)
        mock.setClusterApprovals(body: try ClusterApprovalMacs.body([operatorRow]))
        mock.setOwnerApprovals(body: try owned([own]))
        #expect(await ClusterApprovalFetch.fetch(providerConfiguration: macs.leader.provider, token: "account-token")
            == .approvals([operatorRow, own]))
        #expect(mock.snapshot().ownerApprovalAuthorizations == ["Bearer account-token"])
        // Without a credential only the public list is asked.
        #expect(await ClusterApprovalFetch.fetch(providerConfiguration: macs.leader.provider, token: nil) == .approvals([operatorRow]))
        #expect(mock.snapshot().ownerApprovalAuthorizations.count == 1)
        // A public 404 with own approvals: the own approvals.
        mock.setClusterApprovals(body: nil)
        #expect(await ClusterApprovalFetch.fetch(providerConfiguration: macs.leader.provider, token: "t") == .approvals([own]))
        await mock.shutdown()
    }

    @Test func anAccountWithoutOwnApprovalsLeavesThePublicAnswerAsItIs() async throws {
        let (mock, url) = try await coordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        let operatorRow = macs.approval()
        for status in [401, 403, 404] {
            mock.setOwnerApprovals(status: status, body: Data("{}".utf8))
            mock.setClusterApprovals(body: try ClusterApprovalMacs.body([operatorRow]))
            #expect(await ClusterApprovalFetch.fetch(providerConfiguration: macs.leader.provider, token: "t") == .approvals([operatorRow]))
            mock.setClusterApprovals(body: nil)
            #expect(await ClusterApprovalFetch.fetch(providerConfiguration: macs.leader.provider, token: "t") == .notOffered)
        }
        await mock.shutdown()
    }

    @Test func aFailedHalfIsTheAnswer() async throws {
        let (mock, url) = try await coordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: url)
        mock.setClusterApprovals(body: try ClusterApprovalMacs.body([macs.approval()]))
        mock.setOwnerApprovals(status: 500, body: Data("{}".utf8))
        #expect(await ClusterApprovalFetch.fetch(providerConfiguration: macs.leader.provider, token: "t") == .unavailable("HTTP 500"))
        mock.setOwnerApprovals(body: try owned([macs.modelApproval()]))
        mock.setClusterApprovals(status: 502, body: Data("{}".utf8))
        #expect(await ClusterApprovalFetch.fetch(providerConfiguration: macs.leader.provider, token: "t") == .unavailable("HTTP 502"))
        // The combination itself, for the outcomes no server is needed for.
        #expect(ClusterApprovalFetch.combined(.notOffered, owned: .unreachable("down")) == .unreachable("down"))
        #expect(ClusterApprovalFetch.combined(.unreachable("down"), owned: .approvals([])) == .unreachable("down"))
        await mock.shutdown()
    }

    @Test func anOwnApprovalsAnswerIsReadStrictly() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        let own = macs.modelApproval(id: Self.ownID)
        #expect(try ClusterApprovalFetch.decodeOwned(try owned([own])) == [own])
        var extra = try entry(own); extra["generation"] = 1
        var unknown = try entry(own)
        var approval = unknown["approval"] as! [String: Any]; approval["granted"] = true; unknown["approval"] = approval
        let refused: [(String, Any)] = [
            ("another top-level field", ["approvals": [try entry(own)], "next": ""] as [String: Any]),
            ("an extra entry field", ["approvals": [extra]] as [String: Any]),
            ("an unknown approval field", ["approvals": [unknown]] as [String: Any]),
            ("a policy_sha256 this Mac does not derive", ["approvals": [try entry(own, policy: ClusterApprovalMacs.hash("0"))]] as [String: Any]),
            ("too many entries", ["approvals": Array(repeating: try entry(own), count: ClusterApprovalFetch.maximumApprovals + 1)] as [String: Any]),
            ("not a list", ["approvals": "none"] as [String: Any]),
        ]
        for (name, object) in refused {
            #expect(throws: ClusterConfigurationError.self, "\(name) was taken") {
                try ClusterApprovalFetch.decodeOwned(try JSONSerialization.data(withJSONObject: object))
            }
        }
        // A registration's answer is one entry, read the same way.
        #expect(throws: ClusterConfigurationError.self) {
            try ClusterApprovalFetch.decodeOwnedEntry(try JSONSerialization.data(withJSONObject: try entry(own, policy: ClusterApprovalMacs.hash("0"))))
        }
        #expect(throws: ClusterConfigurationError.self) {
            try ClusterApprovalFetch.decodeOwnedEntry(try owned([own]))
        }
    }
}
