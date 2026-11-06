import Foundation
import DarkbloomClusterProtocol

/// Mirror of protocol/native_pair_intent.go. Local consent cannot authorize a child.
struct NativePairIntent: Sendable, Equatable {
    let clusterID, approvalID: String
    let policySHA256: Data
    let memberIDs: [String]
    let signerSHA256: [Data]
    let rank: UInt8
    let lifetimeSeconds: UInt32
    func canonical() throws -> Data {
        func text(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 128 && s.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value != 127 } }
        func hash(_ h: Data) -> Bool { h.count == 32 && h.contains(where: { $0 != 0 }) }
        guard text(clusterID), text(approvalID), hash(policySHA256), rank < 2, lifetimeSeconds == 300,
              memberIDs.count == 2, signerSHA256.count == 2, Set(memberIDs).count == 2,
              signerSHA256[0] != signerSHA256[1], memberIDs.allSatisfy(text), signerSHA256.allSatisfy(hash) else { throw NativePairMemberError.binding }
        var b = Data("DBNIC\u{1}".utf8)
        func integer<T: FixedWidthInteger & UnsignedInteger>(_ n: T) { for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { b.append(UInt8(truncatingIfNeeded: n >> shift)) } }
        func string(_ s: String) { let raw = Data(s.utf8); integer(UInt32(raw.count)); b.append(raw) }
        string(clusterID); string(approvalID); b.append(policySHA256)
        for i in 0..<2 { string(memberIDs[i]); b.append(signerSHA256[i]) }
        b.append(rank); integer(lifetimeSeconds); return b
    }
    init(clusterID: String, approvalID: String, policySHA256: Data, memberIDs: [String], signerSHA256: [Data], rank: UInt8, lifetimeSeconds: UInt32 = 300) throws {
        self.clusterID = clusterID; self.approvalID = approvalID; self.policySHA256 = policySHA256
        self.memberIDs = memberIDs; self.signerSHA256 = signerSHA256; self.rank = rank; self.lifetimeSeconds = lifetimeSeconds
        _ = try canonical()
    }
    init(_ bytes: Data) throws {
        var r = NativePairMemberPolicy.Reader(bytes)
        try r.literal(Data("DBNIC\u{1}".utf8))
        let cluster = try r.string(maximum: 128), approval = try r.string(maximum: 128), policy = try r.read(32)
        var members = [String](), signers = [Data]()
        for _ in 0..<2 { members.append(try r.string(maximum: 128)); signers.append(try r.read(32)) }
        try self.init(clusterID: cluster, approvalID: approval, policySHA256: policy, memberIDs: members, signerSHA256: signers,
            rank: r.integer(UInt8.self), lifetimeSeconds: r.integer(UInt32.self))
        guard r.remaining == 0, try canonical() == bytes else { throw NativePairMemberError.binding }
    }
}

struct NativePairIntentMessage: Codable, Sendable {
    let type: String, version: UInt8, memberNonce: String, sequence: UInt64, payload: String, signature: String?
    enum CodingKeys: String, CodingKey { case type, version, sequence, payload, signature; case memberNonce = "member_nonce" }
    init(nonce: String, sequence: UInt64, intent: NativePairIntent, signature: Data? = nil) throws {
        type = "native_pair_intent"; version = 1; memberNonce = nonce; self.sequence = sequence
        payload = try intent.canonical().base64EncodedString(); self.signature = signature?.base64EncodedString(); try validate()
    }
    func validate() throws {
        guard type == "native_pair_intent", version == 1, sequence > 0,
              memberNonce.count == 64, memberNonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              memberNonce.contains(where: { $0 != "0" }), let raw = Data(base64Encoded: payload), raw.count <= 1024,
              raw.base64EncodedString() == payload else { throw NativePairMemberError.binding }
        _ = try NativePairIntent(raw)
        if let signature { guard let raw = Data(base64Encoded: signature), (8...72).contains(raw.count), raw.base64EncodedString() == signature else { throw NativePairMemberError.binding } }
    }
    func signingBytes() throws -> Data {
        try validate(); var b = Data("darkbloom/coordinator-native-pair/configuration-intent/v1\0".utf8)
        func integer<T: FixedWidthInteger & UnsignedInteger>(_ n: T) { for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { b.append(UInt8(truncatingIfNeeded: n >> shift)) } }
        for s in [type, memberNonce] { let raw = Data(s.utf8); integer(UInt32(raw.count)); b.append(raw) }
        b.append(version); integer(sequence); let raw = Data(base64Encoded: payload)!; integer(UInt32(raw.count)); b.append(raw); return b
    }
    static func decode(_ raw: Data) throws -> Self {
        guard !raw.isEmpty, raw.count <= 4096, !raw.contains(10) else { throw NativePairMemberError.binding }
        var framed = raw; framed.append(10); try validateClusterWorkerEnvelope(framed, commandStream: true)
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], Set(o.keys) == Set(["type", "version", "member_nonce", "sequence", "payload", "signature"]), !o.values.contains(where: { $0 is NSNull }) else { throw NativePairMemberError.binding }
        let m = try JSONDecoder().decode(Self.self, from: raw); try m.validate(); guard m.signature != nil else { throw NativePairMemberError.binding }; return m
    }
}
