import Foundation
import Testing
import MLXLMCommon
@testable import ProviderCore

private func clusterHTTPObservation(_ session: LocalHostTestSession) throws -> ClusterSessionObservation {
    let pin = String(repeating: "a", count: 64)
    let object: [String: Any] = ["clusterID": "fixture-cluster", "memberID": session.expectedIdentity.peers[0].id,
        "role": "leader", "configurationSHA256": pin, "capabilitySHA256": pin,
        "publicModelID": session.model.publicModelID, "runtimeModelID": session.expectedIdentity.modelID,
        "artifactSHA256": pin, "configurationModelSHA256": pin, "planSHA256": pin,
        "prefillSchedule": "serial_v1", "maximumLifetimeSeconds": 10, "maximumRequests": 16,
        "peers": session.expectedIdentity.peers.enumerated().map { rank, peer in
            ["id": peer.id, "rank": rank, "runtimeBinarySHA256": peer.buildSHA256] as [String: Any]
        }]
    let binding = try JSONDecoder().decode(ClusterStatusBinding.self, from: JSONSerialization.data(withJSONObject: object))
    return .init(binding: binding, phase: "ready", observedMembershipEpoch: session.expectedIdentity.membershipEpoch.uuidString.lowercased(),
        observedPrefillSchedule: .serial, ready: true,
        admission: .init(remainingLifetimeNanoseconds: 4_000_000_000, remainingRequests: 16,
            activeRequest: false, draining: false, valid: true),
        members: session.expectedIdentity.peers.enumerated().map { rank, peer in
            .init(peerID: peer.id, rank: rank, transport: rank == 0 ? .localPipes : .authenticatedSSH,
                nativeReady: true, requestCapacityBytes: 1024, nativeCleanupObserved: false,
                ownerReleaseAcknowledged: false, ownerTermination: nil)
        }, mtpEnabled: false, mtpOffReason: "runtimeCapabilityDisablesSpeculation")
}

private func clusterHTTPGet(_ port: UInt16, nonce: String?, token: String?) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/cluster/status")!)
    request.timeoutInterval = 2
    if let nonce { request.setValue(nonce, forHTTPHeaderField: ClusterStatusCodec.nonceHeader) }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (body, response) = try await URLSession.shared.data(for: request)
    return (body, response as! HTTPURLResponse)
}

@Test func clusterStatusUsesNormalBearerPolicyAndFreshBoundedResponse() async throws {
    let session = LocalHostTestSession()
    session.observation = try clusterHTTPObservation(session)
    let host = DistributedLocalServer(session: session, config: .init(authToken: "fixture-token"),
        tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) })
    try await host.start()
    let port = try #require(await host.status.boundPort)
    let nonce = UUID().uuidString.lowercased()
    let (_, absent) = try await clusterHTTPGet(port, nonce: nonce, token: nil)
    #expect(absent.statusCode == 401)
    let (_, wrong) = try await clusterHTTPGet(port, nonce: nonce, token: "wrong")
    #expect(wrong.statusCode == 401)
    let (_, noNonce) = try await clusterHTTPGet(port, nonce: nil, token: "fixture-token")
    #expect(noNonce.statusCode == 400 && noNonce.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    let (bytes, response) = try await clusterHTTPGet(port, nonce: nonce, token: "fixture-token")
    #expect(response.statusCode == 200 && response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    let sample = try ClusterStatusCodec.decode(bytes, nonce: nonce, binding: session.observation!.binding,
        authenticationConfigured: true, port: port)
    #expect(sample.ready && sample.admissionAvailable && sample.authenticationConfigured)
    #expect(session.base.reserveCount == 0 && bytes.count <= ClusterStatusCodec.maximumBytes)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("fixture-token"))
    let stopped = await host.stop(until: localHostDeadline())
    #expect(stopped.cleanupComplete)
}

@Test func clusterStatusSupportsExplicitNoAuthAndActualLocalClient() async throws {
    let session = LocalHostTestSession()
    session.observation = try clusterHTTPObservation(session)
    let host = localHost(session)
    try await host.start()
    let port = try #require(await host.status.boundPort)
    let nonce = UUID().uuidString.lowercased()
    let (bytes, response) = try await clusterHTTPGet(port, nonce: nonce, token: nil)
    #expect(response.statusCode == 200)
    let sample = try ClusterStatusCodec.decode(bytes, nonce: nonce, binding: session.observation!.binding,
        authenticationConfigured: false, port: port)
    #expect(!sample.authenticationConfigured && sample.ready)
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".cluster-status-http-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("local.json")
    let info = LocalEndpoint.Info(host: "127.0.0.1", port: port, apiKey: "", version: "fixture", pid: -1, updatedAt: "stale")
    try JSONEncoder().encode(info).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let observed = try await ClusterStatusClient.observe(binding: session.observation!.binding, discoveryURL: file)
    #expect(observed.ready && !observed.authenticationConfigured)
    // The stale/invalid discovery PID was irrelevant: a fresh response was required.
    let stopped = await host.stop(until: localHostDeadline())
    #expect(stopped.cleanupComplete)
    do { _ = try await ClusterStatusClient.observe(binding: session.observation!.binding, discoveryURL: file); Issue.record("Dead listener looked ready") }
    catch {}
}

@Test func clusterStatusWithoutInstalledObservationRefusesRatherThanInferringFromHost() async throws {
    let session = LocalHostTestSession(), host = localHost(session)
    try await host.start()
    let port = try #require(await host.status.boundPort)
    let (_, response) = try await clusterHTTPGet(port, nonce: UUID().uuidString.lowercased(), token: nil)
    #expect(response.statusCode == 503)
    #expect(session.base.reserveCount == 0)
    let stopped = await host.stop(until: localHostDeadline())
    #expect(stopped.cleanupComplete)
}
