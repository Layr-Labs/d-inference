import CryptoKit
import Foundation
import DarkbloomClusterProtocol

/// Public signed wire only. Decoding or constructing these values never mints
/// Completed/Authorized/PeerAdmitted, records an exit or resolves a journal.
enum GLM5NextCalibrationPeerQuoteDocument {
    typealias Q = GLM5NextCalibrationQuoteDocument
    typealias D = GLM5NextCalibrationDocument
    static let domain = Data("darkbloom/glm-completed-peer-quote/v1\0".utf8)
    static let maximumDocumentBytes = 1 << 20
    static let maximumPayloadBytes = 512 << 10

    struct Identity: Codable, Equatable {
        struct Peer: Codable, Equatable { let id: String; let buildSHA256: String }
        let epoch: UUID
        let modelID: String
        let artifactSHA256: String
        let configurationSHA256: String
        let peers: [Peer]
        init(_ identity: ClusterWorkerIdentity) {
            epoch = identity.membershipEpoch; modelID = identity.modelID
            artifactSHA256 = identity.artifactSHA256; configurationSHA256 = identity.configurationSHA256
            peers = identity.peers.map { .init(id: $0.id, buildSHA256: $0.buildSHA256) }
        }
    }
    struct Pair: Codable, Equatable {
        let clusterID: String
        let generation: UInt64
        let rosterSHA256: String
        let ceremonyTranscriptSHA256: String
        let linkEpoch: UUID
        let edgeID: UUID
    }
    struct Body: Codable {
        let version: Int
        let purpose: String
        let pair: Pair
        let identity: Identity
        let rank: Int
        let epoch: UUID
        let requestID: UUID
        let expiresUnixSeconds: Int64
        let signedRequest: Data
        let signedRequestSHA256: String
        let requestSHA256: String
        let response: Data
        let responseSHA256: String
        let observedActualExit: Bool
        let childExitCode: Int
        let journalResolved: Bool
    }

    static func pair(_ pair: GLM5NextCalibrationInstalledPair, identity: ClusterWorkerIdentity, rank: Int) throws -> Pair {
        try pair.requireUnchanged()
        let roster = ClusterRoster(generation: pair.record.roster.generation, members: pair.record.roster.members.map {
            .init(pin: $0.pin, sePublicKey: $0.sePublicKey, signature: $0.signature)
        })
        try roster.verify(clusterID: pair.clusterID)
        let rosterSHA = try roster.sha256(clusterID: pair.clusterID)
        guard (0...1).contains(rank), roster.members.count == 2, identity.peers.count == 2,
              identity.peers.map(\.id) == roster.members.map({ ClusterSetupMemberFacts.memberID(pin: $0.pin) }),
              Set(identity.peers.map(\.id)).count == 2,
              Data(base64Encoded: roster.members[rank].sePublicKey) == pair.localIdentity,
              Data(base64Encoded: roster.members[1 - rank].sePublicKey) == pair.peerIdentity,
              hex(rosterSHA) == pair.record.rosterSHA256,
              D.hashSyntax(pair.record.transcriptSHA256),
              let linkEpoch = UUID(uuidString: pair.record.link.linkEpoch),
              let edgeID = UUID(uuidString: pair.record.link.edgeID) else {
            throw D.invalid("Completed peer quotation differs from the actual paired roster")
        }
        return Pair(clusterID: pair.clusterID, generation: roster.generation, rosterSHA256: hex(rosterSHA),
            ceremonyTranscriptSHA256: pair.record.transcriptSHA256, linkEpoch: linkEpoch, edgeID: edgeID)
    }

    static func verify(_ data: Data, key: Data) throws -> Body {
        let envelope = try envelope(data, maximumDocument: maximumDocumentBytes, maximumPayload: maximumPayloadBytes,
            key: key, domain: domain)
        let body = try JSONDecoder().decode(Body.self, from: envelope.payload)
        guard try Q.canonical(body) == envelope.payload else {
            throw D.invalid("Completed peer quotation contains noncanonical or unknown fields")
        }
        return body
    }

    static func request(_ data: Data, key: Data) throws -> Q.Request {
        let envelope = try envelope(data, maximumDocument: 256 << 10, maximumPayload: 128 << 10,
            key: key, domain: Q.domain)
        let request = try JSONDecoder().decode(Q.Request.self, from: envelope.payload)
        guard try Q.canonical(request) == envelope.payload else {
            throw D.invalid("Signed peer quotation request contains noncanonical or unknown fields")
        }
        return request
    }

    private static func envelope(_ data: Data, maximumDocument: Int, maximumPayload: Int,
                                 key: Data, domain: Data) throws -> D.SignedDocument {
        guard !data.isEmpty, data.count <= maximumDocument else { throw D.invalid("Invalid peer quotation document size") }
        let envelope = try JSONDecoder().decode(D.SignedDocument.self, from: data)
        guard !envelope.payload.isEmpty, envelope.payload.count <= maximumPayload,
              envelope.signature.count == 64, try Q.canonical(envelope) == data else {
            throw D.invalid("Peer quotation envelope is not exact canonical encoding")
        }
        let publicKey = try P256.Signing.PublicKey(x963Representation: key)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: envelope.signature)
        guard publicKey.isValidSignature(signature, for: domain + envelope.payload) else {
            throw D.invalid("Peer quotation document is not signed by the actual paired member")
        }
        return envelope
    }
    static func hash(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
