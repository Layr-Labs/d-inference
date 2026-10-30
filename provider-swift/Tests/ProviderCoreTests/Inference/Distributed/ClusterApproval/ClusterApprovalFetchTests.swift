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
        return [macs.approval(schedule: 1), macs.approval(schedule: 2), macs.modelApproval()]
    }

    @Test func aStrictListIsTakenAndTheRequestHasNoQuery() async throws {
        let (mock, url) = try await coordinator()
        let entries = try approvals()
        mock.setClusterApprovals(body: try ClusterApprovalMacs.body(entries))
        #expect(await ClusterApprovalFetch.fetch(coordinatorURL: url) == .approvals(entries))
        #expect(mock.snapshot().clusterApprovalQueries == [""])
        await mock.shutdown()
    }

    @Test func notFoundMeansNotOffered() async throws {
        let (mock, url) = try await coordinator()
        #expect(await ClusterApprovalFetch.fetch(coordinatorURL: url) == .notOffered)
        await mock.shutdown()
    }

    @Test func everyOtherAnswerIsNoApproval() async throws {
        let (mock, url) = try await coordinator()
        let all = try approvals()
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(all[0])) as! [String: Any]
        func list(_ entries: [[String: Any]], schema: String = ClusterApprovalFetch.schemaName, extra: [String: Any] = [:]) throws -> Data {
            var object: [String: Any] = ["schema": schema, "cluster_approvals": entries]
            extra.forEach { object[$0] = $1 }
            return try JSONSerialization.data(withJSONObject: object)
        }
        var unknown = entry; unknown["granted"] = true
        var missing = entry; missing.removeValue(forKey: "resource_policy_sha256")
        var badDigest = entry; badDigest["metallib_sha256"] = "ABC"
        var badExpiry = entry; badExpiry["not_after"] = "in two weeks"
        // A model approval (no runtime digests) with one runtime digest, or without one of its own fields; a
        // build-pinned entry whose runtime digests are null.
        let model = try JSONSerialization.jsonObject(with: JSONEncoder().encode(all[2])) as! [String: Any]
        var partial = model; partial["native_runtime_sha256"] = entry["native_runtime_sha256"]
        var modelMissing = model; modelMissing.removeValue(forKey: "allowed_numerics_classes")
        var nulls = entry
        for key in ClusterRuntimeApproval.runtimeKeys { nulls[key.rawValue] = NSNull() }
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
            ("a model approval with one runtime digest", 200, try list([model, partial]), nil),
            ("a model approval without its numerics classes", 200, try list([entry, modelMissing]), nil),
            ("a build-pinned entry with null runtime digests", 200, try list([nulls]), nil),
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

    @Test func anAnswerWhoseBodyBreaksOffIsAnAnswerNotUnreachable() async throws {
        // A real HTTP server on this Mac's loopback that sends a 200 head promising more bytes than it sends, then
        // closes: the coordinator answered, so an offered pair must not count this toward the no-answer grace.
        let server = try TruncatingHTTPServer()
        let outcome = await ClusterApprovalFetch.fetch(coordinatorURL: "ws://127.0.0.1:\(server.port)/ws/provider")
        server.close()
        guard case .unavailable(let reason) = outcome else { Issue.record("a broken body was \(outcome)"); return }
        #expect(reason.hasPrefix("the answer could not be read"), "\(reason)")
    }

    @Test func onlyHTTPSOrThisMacsLoopbackIsAsked() async throws {
        #expect(ClusterApprovalFetch.url(coordinatorURL: "wss://api.dev.darkbloom.xyz/ws/provider")?.absoluteString
            == "https://api.dev.darkbloom.xyz/v1/cluster/approvals")
        #expect(ClusterApprovalFetch.url(coordinatorURL: "ws://127.0.0.1:8080/ws/provider") != nil)
        for refused in ["ws://coordinator.example/ws/provider", "http://10.0.0.1/ws/provider", "ftp://host/x",
                        "wss://host/ws/provider?token=1", "not a url"] {
            #expect(ClusterApprovalFetch.url(coordinatorURL: refused) == nil, "\(refused) must not be asked")
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

/// One HTTP exchange on a loopback port: reads the request head, answers `200` with a `Content-Length` far beyond the
/// bytes it then sends, and closes the connection.
private final class TruncatingHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let done = DispatchSemaphore(value: 0)

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("no socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw ClusterConfigurationError.invalid("no listener") }
        var assigned = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: assigned.sin_port)
        let done = self.done
        Thread.detachNewThread {
            defer { done.signal() }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var head = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                let count = Darwin.read(connection, &buffer, buffer.count)
                guard count > 0 else { return }
                head.append(contentsOf: buffer.prefix(count))
            }
            let answer = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n{\"schema\"".utf8)
            _ = answer.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
        }
    }

    func close() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        _ = done.wait(timeout: .now() + 10)
    }
}
