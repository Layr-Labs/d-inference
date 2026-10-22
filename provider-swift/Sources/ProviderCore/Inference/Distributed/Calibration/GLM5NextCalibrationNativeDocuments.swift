import CryptoKit
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Authenticates public documents. This helper returns public common metadata,
/// never Admission/Committed. Only NativeStart.admit can connect it to the
/// authorizer-only Completed context and an independently held local authority.
enum GLM5NextCalibrationNativeDocuments {
    private typealias D = GLM5NextCalibrationDocument
    private struct PairedMembership: Encodable {
        let domain = "darkbloom/glm-finite-paired-membership/v1"
        let clusterID: String
        let rosterSHA256: String
        let generation: UInt64
        let ceremonyTranscriptSHA256: String
        let linkEpoch: UUID
        let edgeID: UUID
    }

    static func common(documents: [Data], identity: ClusterWorkerIdentity,
                       pair: GLM5NextCalibrationInstalledPair, localRank: Int,
                       expectedVocabularySize: Int, now: Int64) throws -> ClusterNativeAuthorizationCommon {
        try pair.requireUnchanged()
        let roster = ClusterRoster(generation: pair.record.roster.generation, members: pair.record.roster.members.map {
            .init(pin: $0.pin, sePublicKey: $0.sePublicKey, signature: $0.signature)
        })
        try roster.verify(clusterID: pair.clusterID)
        let rosterSHA = try roster.sha256(clusterID: pair.clusterID)
        guard documents.count == 2, (0...1).contains(localRank), roster.members.count == 2,
              hex(rosterSHA) == pair.record.rosterSHA256,
              let local = Data(base64Encoded: roster.members[localRank].sePublicKey), local == pair.localIdentity,
              let peer = Data(base64Encoded: roster.members[1 - localRank].sePublicKey), peer == pair.peerIdentity,
              identity.peers.count == 2,
              identity.peers.map(\.id) == roster.members.map({ ClusterSetupMemberFacts.memberID(pin: $0.pin) }),
              Set(identity.peers.map(\.id)).count == 2 else {
            throw D.invalid("Finite native start differs from the actual paired rank roster")
        }
        guard D.hashSyntax(pair.record.transcriptSHA256),
              let linkEpoch = UUID(uuidString: pair.record.link.linkEpoch),
              let edgeID = UUID(uuidString: pair.record.link.edgeID) else {
            throw D.invalid("Invalid retained pairing ceremony binding")
        }
        let membership = PairedMembership(clusterID: pair.clusterID, rosterSHA256: hex(rosterSHA),
            generation: roster.generation, ceremonyTranscriptSHA256: pair.record.transcriptSHA256,
            linkEpoch: linkEpoch, edgeID: edgeID)
        let bodies = try (0...1).map { rank -> D.Body in
            let key = try P256.Signing.PublicKey(x963Representation:
                rank == localRank ? pair.localIdentity : pair.peerIdentity)
            let body = try verify(documents[rank], key: key)
            try D.validate(body, identity: identity, rank: rank, now: now, expectedVocabularySize: expectedVocabularySize)
            let variables = body.selection.environment.variableSHA256
            let otherKey = rank == localRank ? pair.peerIdentity : pair.localIdentity
            guard variables[GLM5NextCalibrationLaunch.peerIdentityVariable]
                    == GLM5NextCalibrationLaunch.digest(GLM5NextCalibrationLaunch.peerFingerprint(otherKey)),
                  variables[GLM5NextCalibrationLaunch.appIdentityVariable] != nil,
                  // This narrowly versioned calibration lane is explicitly FP32.
                  // No product default is changed or general precision approved.
                  variables["MLX_ENABLE_TF32"] == GLM5NextCalibrationLaunch.digest("0") else {
                throw D.invalid("Finite native start has a different paired identity or precision contract")
            }
            return body
        }
        let left = bodies[0], right = bodies[1]
        guard try commonSelection(left.selection) == commonSelection(right.selection),
              left.binding == right.binding,
              left.authorization.requestID == right.authorization.requestID,
              left.authorization.promptTokenIDs == right.authorization.promptTokenIDs,
              left.authorization.outputCount == right.authorization.outputCount,
              left.authorization.chunkSize == right.authorization.chunkSize else {
            throw D.invalid("Finite native documents differ in artifact, binding or one-request scope")
        }
        // These are record codec safety ceilings, not measured tensor/model
        // budgets or an allocation claim. The signed rank-local model/resource
        // bounds remain unchanged and must still be enforced at LOAD/request.
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: 1 << 20,
            maximumRecordsPerDirection: 4096, maximumCumulativePlaintextBytesPerDirection: 256 << 20)
        let common = try ClusterNativeAuthorizationCommon(
            finiteCalibrationRequestID: left.authorization.requestID,
            expiresUnixSeconds: left.selection.expiresUnixSeconds, epoch: left.selection.epoch,
            membershipGeneration: roster.generation, membershipTranscriptSHA256: digest(canonical(membership)),
            planSHA256: bytes(left.binding.executionPlanSHA256), artifactSHA256: bytes(left.selection.artifactSHA256),
            profileSHA256: digest(canonical(left.binding.profile)),
            rank0AuthorizationSHA256: digest(documents[0]), rank1AuthorizationSHA256: digest(documents[1]),
            maximumTransportFrameBytes: limits.maximumPlaintextBytes + 40, limits: limits)
        try pair.requireUnchanged()
        return common
    }

    private static func verify(_ data: Data, key: P256.Signing.PublicKey) throws -> D.Body {
        guard !data.isEmpty, data.count <= 256 << 10 else { throw D.invalid("Invalid finite signed document size") }
        let document = try JSONDecoder().decode(D.SignedDocument.self, from: data)
        guard !document.payload.isEmpty, document.payload.count <= 128 << 10,
              document.signature.count == 64, try canonical(document) == data else {
            throw D.invalid("Finite signed document is not exact canonical encoding")
        }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: document.signature)
        guard key.isValidSignature(signature, for: D.domain + document.payload) else {
            throw D.invalid("Finite signed document is not authorized by its actual paired rank")
        }
        let body = try JSONDecoder().decode(D.Body.self, from: document.payload)
        guard try canonical(body) == document.payload else {
            throw D.invalid("Finite signed payload contains unknown or noncanonical fields")
        }
        return body
    }

    private static func commonSelection(_ value: D.Payload) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: canonical(value)) as? [String: Any] else {
            throw D.invalid("Invalid finite selection")
        }
        // Quoted capacity, machine facts and allocator quanta are rank-local.
        // Exact signed document hashes bind every omitted value independently.
        for key in ["rank", "environment", "hostAllocationQuantum", "hostAllocationOverhead",
                    "loadCapacityBytes", "requestCapacityBytes"] { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func bytes(_ text: String) throws -> Data {
        guard D.hashSyntax(text) else { throw D.invalid("Invalid finite digest") }
        let chars = Array(text)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
}
