import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@_spi(OwnerService) import DarkbloomClusterRemote
@testable import ProviderCore

/// UNRUN. Two actual task-private metadata fixture children, independently signed
/// by opposite in-memory paired members and actually reaped through Completed.
/// Shares only public pinned config/index metadata and the fixture app/AOT;
/// never a native model, real app install or real production key. The test
/// receive adapters below model the trusted parent's channel seam, NOT actual
/// cable-control qualification. Production must supply that authenticated path.
final class GLM5NextCalibrationPeerQuoteFixture {
    typealias C = GLM5NextCalibrationInstalledQuote
    typealias Q = GLM5NextCalibrationQuoteDocument
    typealias D = GLM5NextCalibrationDocument
    typealias W = GLM5NextCalibrationPeerQuoteDocument
    typealias P = GLM5NextCalibrationPeerQuote
    let base: GLM5NextCalibrationInstalledQuoteCompletedTests.Fixture
    let local: C.Completed
    let peer: C.Completed
    let peerDevice: URL
    let now: Int64
    var deadline: UInt64 { DispatchTime.now().uptimeNanoseconds + 1_000_000_000 }
    var peerSigner: GLM5NextCalibrationAuthorizerTests.Signer { base.pairing.peer }
    var localSigner: GLM5NextCalibrationAuthorizerTests.Signer { base.pairing.local }

    init() throws {
        let base = try GLM5NextCalibrationInstalledQuoteCompletedTests.Fixture()
        let original = try JSONDecoder().decode(C.Input.self, from: Data(contentsOf: base.input))
        var input = try Self.object(original)
        input["peerBinarySHA256"] = try Self.hash(base.worker)
        var request = input["request"] as! [String: Any]
        var selection = request["selection"] as! [String: Any]
        var environment = input["environment"] as! [String: String]
        environment["MLX_ENABLE_TF32"] = "0"
        var facts = selection["environment"] as! [String: Any]
        facts["variableSHA256"] = Self.variables(environment)
        selection["environment"] = facts; request["selection"] = selection
        input["request"] = request; input["environment"] = environment
        try Self.json(input).write(to: base.input)
        let local = try base.complete() // Actual exit + resolved local quotation lease.
        let root = base.device.deletingLastPathComponent()
        let peerStoreRoot = root.appendingPathComponent("opposite-pair")
        let peerDevice = root.appendingPathComponent("opposite-device")
        for directory in [peerStoreRoot, peerDevice] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        // Exact same ceremony/roster/edge; reverse only local/peer-relative fields.
        var record = try Self.object(local.pair.record)
        let localPin = ClusterMemberPin.of(uncompressedKey: local.pair.localIdentity)
        record["peerPin"] = localPin
        record["peerIdentityKey"] = local.pair.localIdentity.base64EncodedString()
        let records: [String: Any] = ["schema": ClusterPairingRecords.schemaName,
            "localPin": base.pairing.peerPin, "localIdentityKey": local.pair.peerIdentity.base64EncodedString(),
            "pairings": [record]]
        let store = ClusterPairingStore(directory: peerStoreRoot)
        try Self.json(records).write(to: store.recordsFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.recordsFile.path)
        input["peerPin"] = localPin
        request["quoteRequestID"] = UUID().uuidString // Quote IDs are rank-local; finite request is shared.
        let fingerprint = GLM5NextCalibrationLaunch.peerFingerprint(local.pair.localIdentity)
        request["peerIdentitySHA256"] = fingerprint
        selection["rank"] = 1 - local.authorized.request.selection.rank
        environment["JACCL_RANK"] = String(1 - local.authorized.request.selection.rank)
        environment[GLM5NextCalibrationLaunch.peerIdentityVariable] = fingerprint
        facts["deviceRegistryID"] = 2; facts["deviceName"] = "Opposite fixture device"
        facts["variableSHA256"] = Self.variables(environment)
        selection["hostAllocationQuantum"] = 32; selection["hostAllocationOverhead"] = 16
        selection["environment"] = facts; request["selection"] = selection
        var resources = request["authorization"] as! [String: Any]
        resources["nativeHardCapBytes"] = 2100; resources["hostBudgetBytes"] = 1100
        resources["osHeadroomBytes"] = 1200
        resources["workspaceNativeAllowanceBytes"] = 101; resources["workspaceHostAllowanceBytes"] = 101
        request["authorization"] = resources; input["request"] = request; input["environment"] = environment
        let peerInput = root.appendingPathComponent("opposite-input.json")
        try Self.json(input).write(to: peerInput)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: peerInput.path)
        let peer = try C.complete(input: peerInput, installedExecutable: base.app, deviceDirectory: peerDevice,
            quoteTimeoutNanoseconds: base.timeout, loadPair: { cluster, pin in
                try GLM5NextCalibrationInstalledPair.load(clusterID: cluster, peerPin: pin,
                    store: store, loadSigner: { base.pairing.peer })
            })
        self.base = base; self.local = local; self.peer = peer; self.peerDevice = peerDevice
        now = Int64(Date().timeIntervalSince1970)
    }

    func requireBothFreshLeases() throws {
        try base.requireFreshDeviceLease()
        let lease = try ClusterDeviceLease(directoryURL: peerDevice)
        let rank = peer.authorized.request.selection.rank
        try lease.record(clusterID: peer.pair.clusterID, peerID: peer.authorized.identity.peers[rank].id,
            rank: rank, membershipEpoch: peer.authorized.identity.membershipEpoch,
            leaseID: UUID(), ownerIncarnation: UUID(), nativeLaunchID: UUID())
        try lease.resolve()
    }
    func summary() throws -> Data { try P.outbound(completed: peer, now: now, deadline: deadline) }
    func admit(_ data: Data, now: Int64? = nil) throws -> P.PeerAdmitted {
        try P.admit(completed: local, receiveFromAuthenticatedPair: { pair, _ in
            // Test adapter only; checks the exact expected pair but does not
            // claim an actual network channel. Real transport is parent-owned.
            #expect(pair.record == self.local.pair.record)
            return data
        }, now: now ?? self.now, deadline: deadline)
    }
    func body(_ data: Data) throws -> [String: Any] {
        let envelope = try JSONDecoder().decode(D.SignedDocument.self, from: data)
        return try JSONSerialization.jsonObject(with: envelope.payload) as! [String: Any]
    }
    func signed(_ body: [String: Any], domain: Data = W.domain,
                signer: GLM5NextCalibrationAuthorizerTests.Signer? = nil) throws -> Data {
        let payload = try Self.json(body)
        return try Q.canonical(D.SignedDocument(payload: payload,
            signature: (signer ?? peerSigner).key.signature(for: domain + payload).rawRepresentation))
    }
    /// Re-sign mutation fixtures without ever constructing peer Authorized or
    /// Completed. Only used to prove rejection of authenticated invalid claims.
    func changingRequest(_ data: Data, change: (inout [String: Any]) -> Void,
                         requestDomain: Data = Q.domain,
                         requestSigner: GLM5NextCalibrationAuthorizerTests.Signer? = nil) throws -> Data {
        var outer = try body(data)
        let signedRequest = try #require(Data(base64Encoded: outer["signedRequest"] as! String))
        let requestEnvelope = try JSONDecoder().decode(D.SignedDocument.self, from: signedRequest)
        var request = try JSONSerialization.jsonObject(with: requestEnvelope.payload) as! [String: Any]
        change(&request)
        let payload = try Self.json(request), requestHash = W.hash(payload)
        let encoded = try Q.canonical(D.SignedDocument(payload: payload,
            signature: (requestSigner ?? peerSigner).key.signature(for: requestDomain + payload).rawRepresentation))
        outer["signedRequest"] = encoded.base64EncodedString(); outer["signedRequestSHA256"] = W.hash(encoded)
        outer["requestSHA256"] = requestHash
        // Update response request/environment digests so request mutations are
        // checked against identity/common/bounds, not merely stale hashes.
        let rawResponse = try #require(Data(base64Encoded: outer["response"] as! String))
        var response = try JSONSerialization.jsonObject(with: rawResponse) as! [String: Any]
        response["quoteRequestSHA256"] = requestHash; response["quoteRequestID"] = request["quoteRequestID"]
        let selection = request["selection"] as! [String: Any]
        let environment = try Self.json(selection["environment"] as! [String: Any])
        response["executionEnvironmentSHA256"] = W.hash(environment)
        let responseData = try Self.json(response)
        outer["response"] = responseData.base64EncodedString(); outer["responseSHA256"] = W.hash(responseData)
        return try signed(outer)
    }
    func changingResponse(_ data: Data, change: (inout [String: Any]) -> Void) throws -> Data {
        var outer = try body(data)
        let raw = try #require(Data(base64Encoded: outer["response"] as! String))
        var response = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        change(&response)
        let bytes = try Self.json(response)
        outer["response"] = bytes.base64EncodedString(); outer["responseSHA256"] = W.hash(bytes)
        return try signed(outer)
    }
    static func variables(_ environment: [String: String]) -> [String: String] {
        environment.filter { $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_") }
            .mapValues(GLM5NextCalibrationLaunch.digest)
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Q.canonical(value)) as! [String: Any]
    }
    static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func hash(_ url: URL) throws -> String { W.hash(try Data(contentsOf: url)) }
    static func set(_ value: inout [String: Any], path: [String], to replacement: Any) {
        if path.count == 1 { value[path[0]] = replacement; return }
        var child = value[path[0]] as! [String: Any]
        set(&child, path: Array(path.dropFirst()), to: replacement); value[path[0]] = child
    }
}
