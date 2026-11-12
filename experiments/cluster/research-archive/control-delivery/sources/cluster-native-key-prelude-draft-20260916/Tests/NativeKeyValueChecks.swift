import CryptoKit
import Foundation
@testable import DarkbloomClusterBootstrap
@testable import DarkbloomClusterSecurity

enum NativeFixtureFailure: Error { case failed(String) }
func requireNative(_ yes: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try yes() else { throw NativeFixtureFailure.failed(name) }
}
func rejectNative(_ name: String, _ body: () throws -> Void) throws {
    do { try body() } catch is NativeFixtureFailure { throw NativeFixtureFailure.failed(name) } catch { return }
    throw NativeFixtureFailure.failed(name)
}
func fixtureHex(_ value: String) throws -> Data {
    guard value.count % 2 == 0 else { throw NativeFixtureFailure.failed("fixture hex") }
    var out = Data(), index = value.startIndex
    while index < value.endIndex {
        let end = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<end], radix: 16) else { throw NativeFixtureFailure.failed("fixture hex") }
        out.append(byte); index = end
    }
    return out
}
func fixtureStarts() throws -> [ClusterNativeAuthorizationStart] {
    let digests = (0..<8).map { Data(SHA256.hash(data: Data("fixture-native-field-\($0)".utf8))) }
    let common = try ClusterNativeAuthorizationCommon(epoch: UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10")!,
        membershipGeneration: 7, nativePolicyGeneration: 11,
        membershipTranscriptSHA256: digests[0], approvedNativeBindingSHA256: digests[1], planSHA256: digests[2],
        artifactSHA256: digests[3], nativeRuntimeSHA256: digests[4], capabilitySHA256: digests[5],
        resourcePolicySHA256: digests[6], profileSHA256: digests[7], schedule: .oneChunkLookahead,
        maximumTransportFrameBytes: 4136,
        limits: .init(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64, maximumCumulativePlaintextBytesPerDirection: 262144))
    func id(_ number: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number))! }
    return try (0..<2).map { rank in try .init(common: common, rank: rank,
        ownerIncarnation: id(100 + 10 * rank), leaseID: id(101 + 10 * rank), launchID: id(102 + 10 * rank)) }
}

func nativeValueChecks(vectorURL: URL) throws {
    let raw = try Data(contentsOf: vectorURL)
    try requireNative(raw.count <= 32 * 1024, "vector bound")
    guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any], object["fixtureOnly"] as? Bool == true else {
        throw NativeFixtureFailure.failed("fixture provenance")
    }
    func bytes(_ field: String) throws -> Data {
        guard let value = object[field] as? String else { throw NativeFixtureFailure.failed("fixture field") }
        return try fixtureHex(value)
    }
    func rows(_ field: String) throws -> [Data] {
        guard let values = object[field] as? [String], values.count == 2 else { throw NativeFixtureFailure.failed("fixture rows") }
        return try values.map(fixtureHex)
    }
    let starts = try fixtureStarts(), privateRows = try rows("privateKeys"), publicRows = try rows("publicKeys")
    let expectedStarts = try rows("starts"), expectedHellos = try rows("hellos")
    try requireNative(starts[0].common.canonicalBytes == bytes("common"), "independent common bytes")
    var hellos: [ClusterNativeKeyHello] = []
    for rank in 0..<2 {
        try requireNative(starts[rank].canonicalBytes == expectedStarts[rank], "independent start bytes")
        let parsed = try ClusterNativeAuthorizationStart(encoded: expectedStarts[rank])
        try requireNative(parsed.canonicalBytes == expectedStarts[rank], "start decode")
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateRows[rank])
        try requireNative(key.publicKey.rawRepresentation == publicRows[rank], "independent X25519 public key")
        let hello = try ClusterNativeKeyHello(start: starts[rank], publicKey: publicRows[rank])
        try requireNative(hello.canonicalBytes == expectedHellos[rank], "independent hello bytes")
        hellos.append(hello)
    }
    let binding = try ClusterNativeKeyBinding(hellos: hellos), encoded = binding.canonicalBytes
    try requireNative(encoded == bytes("binding"), "independent binding bytes")
    try requireNative(binding.transcriptSHA256 == bytes("transcriptSHA256"), "independent transcript")
    try requireNative(ClusterNativeKeyBinding(encoded: encoded).canonicalBytes == encoded, "binding decode")
    let tags = try rows("confirmations")
    for rank in 0..<2 {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateRows[rank])
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicRows[1 - rank])
        let shared = try key.sharedSecretFromKeyAgreement(with: peer)
        try requireNative(shared.withUnsafeBytes { Data($0) } == bytes("sharedSecret"), "independent shared secret")
        let derived = try NativeTrafficKeyDerivation.derive(privateKey: key, peerPublicKey: publicRows[1 - rank], transcriptSHA256: binding.transcriptSHA256)
        try requireNative(derived.recordMaster.withUnsafeBytes { Data($0) } == bytes("recordMaster"), "independent master HKDF")
        try requireNative(derived.confirmation.withUnsafeBytes { Data($0) } == bytes("confirmationKey"), "independent proof HKDF")
        try requireNative(NativeTrafficKeyDerivation.confirmation(rank: rank, transcriptSHA256: binding.transcriptSHA256, key: derived.confirmation) == tags[rank], "independent confirmation")
        try NativeTrafficKeyDerivation.verify(tags[1-rank], rank: 1-rank, transcriptSHA256: binding.transcriptSHA256, key: derived.confirmation)
        try rejectNative("reflection accepted") { try NativeTrafficKeyDerivation.verify(tags[rank], rank: 1-rank, transcriptSHA256: binding.transcriptSHA256, key: derived.confirmation) }
        var wrong = binding.transcriptSHA256; wrong[0] ^= 1
        try rejectNative("transcript accepted") { try NativeTrafficKeyDerivation.verify(tags[1-rank], rank: 1-rank, transcriptSHA256: wrong, key: derived.confirmation) }
        for low in [Data(repeating: 0, count: 32), Data([1]) + Data(repeating: 0, count: 31)] {
            try rejectNative("low order key accepted") { _ = try NativeTrafficKeyDerivation.derive(privateKey: key, peerPublicKey: low, transcriptSHA256: binding.transcriptSHA256) }
        }
    }
    for short in [Data(), Data(encoded.dropLast()), encoded + Data([0])] {
        try rejectNative("truncated/appended transcript") { _ = try ClusterNativeKeyBinding(encoded: short) }
    }
    var unknown = encoded; unknown[4] = 2
    try rejectNative("unknown version") { _ = try ClusterNativeKeyBinding(encoded: unknown) }
    try rejectNative("rank reversal") { _ = try ClusterNativeKeyBinding(hellos: Array(hellos.reversed())) }
    try rejectNative("duplicate hello") { _ = try ClusterNativeKeyBinding(hellos: [hellos[0], hellos[0]]) }
    try rejectNative("extra hello") { _ = try ClusterNativeKeyBinding(hellos: hellos + [hellos[0]]) }
    for malformed in [Data(repeating: 1, count: 31), Data(repeating: 1, count: 33), Data(repeating: 0, count: 32), Data([0xed]) + Data(repeating: 0xff, count: 30) + Data([0x7f])] {
        try rejectNative("noncanonical public key") { _ = try ClusterNativeKeyHello(start: starts[0], publicKey: malformed) }
    }
    let commonStart = ClusterNativeAuthorizationStart.prefix.count
    let policyOffset = commonStart + ClusterNativeAuthorizationCommon.domain.count + 16 + 8 + 8 + 8 * 32
    for offset in [policyOffset, policyOffset + 1, policyOffset + 2] {
        var bytes = starts[0].canonicalBytes; bytes[offset] = 255
        try rejectNative("unknown suite/transport/schedule") { _ = try ClusterNativeAuthorizationStart(encoded: bytes) }
    }
    for range in [(commonStart + ClusterNativeAuthorizationCommon.domain.count)..<(commonStart + ClusterNativeAuthorizationCommon.domain.count + 16),
                  (commonStart + ClusterNativeAuthorizationCommon.domain.count + 16)..<(commonStart + ClusterNativeAuthorizationCommon.domain.count + 24)] {
        var bytes = starts[0].canonicalBytes
        for index in range { bytes[index] = 0 }
        try rejectNative("empty epoch/generation") { _ = try ClusterNativeAuthorizationStart(encoded: bytes) }
    }
    var maximum = starts[0].canonicalBytes
    for index in (policyOffset + 3)..<(policyOffset + 7) { maximum[index] = 255 }
    try rejectNative("unbounded transport frame") { _ = try ClusterNativeAuthorizationStart(encoded: maximum) }
    // The new prelude header never changes the legacy mesh2 encoding.
    let identity = try ClusterBootstrapIdentity(membershipEpoch: starts[0].common.epoch, rank: 0)
    let round = try ClusterBootstrapRound(identity: identity, sequence: 0, contribution: Data([1]))
    try requireNative(BootstrapHeader(round: round, reply: false).encoded().prefix(8) == Data([0x44,0x42,0x4a,0x42,1,1,0,2]), "legacy mesh header changed")
    for kind in [PreludePacket.Kind.confirmation, .peerConfirmation, .complete] {
        try rejectNative("unbounded proof") { _ = try PreludePacket.header(kind: kind, count: 33, identity: identity) }
    }
    try rejectNative("large prelude") { _ = try PreludePacket.header(kind: .binding, count: 32769, identity: identity) }
}
