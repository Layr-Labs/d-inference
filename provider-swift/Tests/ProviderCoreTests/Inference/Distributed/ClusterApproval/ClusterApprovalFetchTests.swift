import Foundation
import Testing
@testable import ProviderCore

/// `GET /v1/cluster/approvals` against a real local HTTP server that answers as the coordinator does: what the
/// provider asks, what it takes, and that every other answer means "no approval".
@Suite("Cluster approval fetch", .serialized)
struct ClusterApprovalFetchTests {
    private func coordinator() async throws -> (MockCoordinator, String) {
        let mock = MockCoordinator()
        let base = try await mock.start()
        return (mock, base.mockProviderWebSocketURL())
    }

    private func approvals() throws -> [ClusterRuntimeApproval] {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        return [macs.approval(schedule: 1), macs.approval(schedule: 2)]
    }

    @Test func aStrictListIsTakenAndTheRequestNamesThisRelease() async throws {
        let (mock, url) = try await coordinator()
        let entries = try approvals()
        mock.setClusterApprovals(body: try ClusterApprovalMacs.body(entries))
        #expect(await ClusterApprovalFetch.fetch(coordinatorURL: url, version: "0.10.4") == .approvals(entries))
        #expect(mock.snapshot().clusterApprovalQueries == ["version=0.10.4&platform=macos-arm64"])
        await mock.shutdown()
    }

    @Test func notFoundMeansNotOffered() async throws {
        let (mock, url) = try await coordinator()
        #expect(await ClusterApprovalFetch.fetch(coordinatorURL: url) == .notOffered)
        await mock.shutdown()
    }

    @Test func everyOtherAnswerIsNoApproval() async throws {
        let (mock, url) = try await coordinator()
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try approvals()[0])) as! [String: Any]
        func list(_ entries: [[String: Any]], schema: String = ClusterApprovalFetch.schemaName, extra: [String: Any] = [:]) throws -> Data {
            var object: [String: Any] = ["schema": schema, "cluster_approvals": entries]
            extra.forEach { object[$0] = $1 }
            return try JSONSerialization.data(withJSONObject: object)
        }
        var unknown = entry; unknown["granted"] = true
        var missing = entry; missing.removeValue(forKey: "resource_policy_sha256")
        var badDigest = entry; badDigest["metallib_sha256"] = "ABC"
        var badExpiry = entry; badExpiry["not_after"] = "in two weeks"
        let refused: [(String, Int, Data, String?)] = [
            ("a server error", 500, Data("{}".utf8), nil),
            ("a redirect", 302, Data(), "https://elsewhere.invalid/v1/cluster/approvals"),
            ("not JSON", 200, Data("approvals".utf8), nil),
            ("another schema", 200, try list([entry], schema: "darkbloom_cluster_catalog_v1"), nil),
            ("an unknown top-level field", 200, try list([entry], extra: ["pairs": []]), nil),
            ("an unknown entry field", 200, try list([unknown]), nil),
            ("a missing entry field", 200, try list([missing]), nil),
            ("a malformed digest", 200, try list([badDigest]), nil),
            ("a malformed not_after", 200, try list([badExpiry]), nil),
            ("too many entries", 200, try list(Array(repeating: entry, count: ClusterApprovalFetch.maximumApprovals + 1)), nil),
            ("an answer over its bound", 200, Data(repeating: 32, count: ClusterApprovalFetch.maximumBytes + 1), nil),
        ]
        for (name, status, body, location) in refused {
            mock.setClusterApprovals(status: status, body: body, location: location)
            let outcome = await ClusterApprovalFetch.fetch(coordinatorURL: url)
            guard case .unavailable = outcome else { Issue.record("\(name) was taken: \(outcome)"); continue }
        }
        // The redirect's target was never asked: only this server's own route saw requests.
        #expect(mock.snapshot().clusterApprovalQueries.count == refused.count)
        await mock.shutdown()
    }

    @Test func onlyHTTPSOrThisMacsLoopbackIsAsked() async throws {
        #expect(ClusterApprovalFetch.url(coordinatorURL: "wss://api.dev.darkbloom.xyz/ws/provider", version: "1.2.3")?.absoluteString
            == "https://api.dev.darkbloom.xyz/v1/cluster/approvals?version=1.2.3&platform=macos-arm64")
        #expect(ClusterApprovalFetch.url(coordinatorURL: "ws://127.0.0.1:8080/ws/provider", version: "1") != nil)
        for refused in ["ws://coordinator.example/ws/provider", "http://10.0.0.1/ws/provider", "ftp://host/x",
                        "wss://host/ws/provider?token=1", "not a url"] {
            #expect(ClusterApprovalFetch.url(coordinatorURL: refused, version: "1") == nil, "\(refused) must not be asked")
        }
        #expect(await ClusterApprovalFetch.fetch(coordinatorURL: "ws://coordinator.example/ws/provider")
            == .unavailable("the coordinator URL is not HTTPS"))
        // Nothing listens on port 9 of this Mac: no answer is no approval, never an error that stops serving, and it
        // is told apart from an answer (an offered pair falls back to local serving only on no answer).
        guard case .unreachable = await ClusterApprovalFetch.fetch(coordinatorURL: "ws://127.0.0.1:9/ws/provider") else {
            Issue.record("an unreachable coordinator was read as an answer"); return
        }
    }
}
