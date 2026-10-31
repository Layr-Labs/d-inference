import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterSecurity
@testable import ProviderCore

@Suite struct GLM5NextCalibrationInstalledPairTests {
    typealias Pair = GLM5NextCalibrationInstalledPair
    typealias Signer = GLM5NextCalibrationAuthorizerTests.Signer

    struct Fixture {
        let root: URL
        let store: ClusterPairingStore
        let local = Signer(), peer = Signer(), newer = Signer()
        let clusterID = "calibration-pair"
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("calibration-pair-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            store = ClusterPairingStore(directory: root)
            try write()
            _ = try #require(try store.load())
        }
        var peerPin: String { ClusterMemberPin.of(uncompressedKey: peer.key.publicKey.x963Representation) }
        func record(_ remote: Signer, timestamp: String) throws -> [String: Any] {
            let keys = [local, remote].map {
                (pin: ClusterMemberPin.of(uncompressedKey: $0.key.publicKey.x963Representation),
                 sePublicKey: $0.key.publicKey.x963Representation.base64EncodedString())
            }.sorted { $0.pin < $1.pin }
            let canonical = try ClusterRoster.canonical(clusterID: clusterID, generation: 1, keys: keys)
            let members: [[String: Any]] = try keys.map { entry in
                let signer = entry.sePublicKey == local.key.publicKey.x963Representation.base64EncodedString() ? local : remote
                return ["pin": entry.pin, "se_public_key": entry.sePublicKey,
                    "signature": try ClusterRoster.signature(over: canonical, signer: signer)]
            }
            return ["peerPin": ClusterMemberPin.of(uncompressedKey: remote.key.publicKey.x963Representation),
                "peerIdentityKey": remote.key.publicKey.x963Representation.base64EncodedString(),
                "peerName": "Test Mac", "peerPosture": ["chipName": "Test", "hardwareModel": "Test",
                    "osVersion": "Test", "sipEnabled": true, "secureBootEnabled": true, "authenticatedRootEnabled": true],
                "role": "listener", "pairedAt": timestamp, "clusterID": clusterID,
                "roster": ["generation": 1, "members": members],
                "rosterSHA256": SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined(),
                "link": ["linkEpoch": UUID().uuidString.lowercased(), "edgeID": UUID().uuidString.lowercased(),
                    "secretFile": root.appendingPathComponent("edge-test.secret").path,
                    "localInterface": "en6", "peerInterface": "en1"],
                "transcriptSHA256": String(repeating: "a", count: 64)]
        }
        func write(change: ((inout [String: Any]) -> Void)? = nil) throws {
            var selected = try record(peer, timestamp: "2026-10-01T00:00:00Z")
            change?(&selected)
            let records: [String: Any] = ["schema": ClusterPairingRecords.schemaName,
                "localPin": ClusterMemberPin.of(uncompressedKey: local.key.publicKey.x963Representation),
                "localIdentityKey": local.key.publicKey.x963Representation.base64EncodedString(),
                "pairings": [selected, try record(newer, timestamp: "2026-10-02T00:00:00Z")]]
            try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(to: store.recordsFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.recordsFile.path)
        }
    }

    @Test func explicitPairWinsOverNewerPairAndRetainsSelection() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pair = try Pair.load(clusterID: f.clusterID, peerPin: f.peerPin, store: f.store, loadSigner: { f.local })
        #expect(pair.peerIdentity == f.peer.key.publicKey.x963Representation)
        #expect(pair.localIdentity == f.local.key.publicKey.x963Representation)
        try pair.requireUnchanged()
        try f.write()
        #expect(throws: (any Error).self) { try pair.requireUnchanged() }
        #expect(throws: (any Error).self) { try pair.linkSecret() }
    }

    @Test func invalidPairNeverLoadsSignerAndWrongSignerNeverSigns() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var loaded = 0
        for (clusterID, peerPin) in [("other-pair", f.peerPin), (f.clusterID, String(repeating: "0", count: 64))] {
            #expect(throws: (any Error).self) {
                try Pair.load(clusterID: clusterID, peerPin: peerPin, store: f.store, loadSigner: { loaded += 1; return f.local })
            }
        }
        #expect(loaded == 0)
        let signaturesBefore = f.newer.calls
        #expect(throws: (any Error).self) {
            try Pair.load(clusterID: f.clusterID, peerPin: f.peerPin, store: f.store, loadSigner: { f.newer })
        }
        #expect(f.newer.calls == signaturesBefore)
    }

    @Test func invalidRosterAndConcurrentPairChangeRefuse() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var loaded = 0
        try f.write { $0["rosterSHA256"] = String(repeating: "0", count: 64) }
        #expect(throws: (any Error).self) {
            try Pair.load(clusterID: f.clusterID, peerPin: f.peerPin, store: f.store, loadSigner: { loaded += 1; return f.local })
        }
        #expect(loaded == 0)
        try f.write()
        #expect(throws: (any Error).self) {
            try Pair.load(clusterID: f.clusterID, peerPin: f.peerPin, store: f.store,
                loadSigner: { try f.write(); return f.local })
        }
    }

    #if DEBUG
    @Test func missingDebugIdentityDoesNotCreateOrReplaceIt() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let missing = f.root.appendingPathComponent("missing-se-handle")
        #expect(throws: (any Error).self) { try SecureEnclaveIdentity.debugLoadExisting(at: missing.path) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let unsafe = f.root.appendingPathComponent("unsafe-se-handle")
        let bytes = Data(repeating: 0x61, count: 32)
        try bytes.write(to: unsafe)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unsafe.path)
        #expect(throws: (any Error).self) { try SecureEnclaveIdentity.debugLoadExisting(at: unsafe.path) }
        #expect(try Data(contentsOf: unsafe) == bytes)
    }
    #endif
}
