import CryptoKit
import Foundation

// S16: the data plane's rekey and its pinned key exchange, on the actual
// Security sources (compiled into this binary), without MLX, a peer or a model.

enum DataPlaneCheckError: Error { case failed(String) }
func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw DataPlaneCheckError.failed(label) }
}
func refuses<E: Error & Equatable>(_ expected: E, _ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch let error as E {
        try require(error == expected, label + ": wrong refusal \(error)")
        return
    } catch { throw DataPlaneCheckError.failed(label + ": unexpected \(error)") }
    throw DataPlaneCheckError.failed(label + ": missing refusal")
}
func refusesAny(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw DataPlaneCheckError.failed(label + ": missing refusal")
}

let epoch = UUID(uuidString: "6b1f0a52-4f6e-4c4b-9a1e-2f3c4d5e6f70")!
let scope = Data(SHA256.hash(data: Data("load agreement".utf8)))
let request = UUID(uuidString: "0e8f4a2c-7b19-4d3e-8a55-1c2d3e4f5a6b")!

func context(_ type: ClusterRecordType = .residualPayload) throws -> ClusterRecordContext {
    try .init(requestID: type == .keepWarm ? nil : request, type: type,
        expectationSHA256: Data(repeating: 7, count: 32))
}
func binding() throws -> ClusterRecordBinding {
    try .init(epoch: epoch, planSHA256: scope, membershipTranscriptSHA256: Data(repeating: 3, count: 32))
}
func limits(records: UInt64 = 1024, bytes: UInt64 = 1 << 20) throws -> ClusterRecordLimits {
    try .init(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: records,
        maximumCumulativePlaintextBytesPerDirection: bytes)
}
final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 1_000
    var now: UInt64 { lock.withLock { value } }
    func advance(seconds: UInt64) { lock.withLock { value += seconds * 1_000_000_000 } }
}
func pair(_ policy: ClusterRecordRekeyPolicy?, clock: Clock = Clock(), key: UInt8 = 9, limits l: ClusterRecordLimits? = nil)
    throws -> (ClusterAuthenticatedRecordChannel, ClusterAuthenticatedRecordChannel) {
    let k = SymmetricKey(data: Data(repeating: key, count: 32))
    let a = try ClusterAuthenticatedRecordChannel(sessionKey: k, binding: binding(), localRank: 0,
        limits: l ?? limits(), rekey: policy, clock: { clock.now })
    let b = try ClusterAuthenticatedRecordChannel(sessionKey: k, binding: binding(), localRank: 1,
        limits: l ?? limits(), rekey: policy, clock: { clock.now })
    return (a, b)
}
func generation(_ record: Data) -> UInt32 { record[20..<24].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }

// MARK: Rekey

func checkRekeyByRecords() throws {
    let (a, b) = try pair(try .init(records: 3, bytes: 1 << 20, seconds: 0))
    var seen: [UInt32] = []
    for index in 0..<10 {
        let payload = Data(repeating: UInt8(index), count: 100)
        let record = try a.seal(payload, context: context())
        seen.append(generation(record))
        try require(try b.open(record, expecting: context()) == payload, "round trip across rekeys")
    }
    try require(seen == [0, 0, 0, 1, 1, 1, 2, 2, 2, 3], "sender moves on every third record: \(seen)")
    try require(a.status.sendGeneration == 3 && b.status.receiveGeneration == 3, "both ends follow")
    // The other direction keeps its own generation.
    let back = try b.seal(Data([1]), context: context())
    let opened = try a.open(back, expecting: context())
    try require(generation(back) == 0 && opened == Data([1]), "directions independent")
    // Records and bytes over the session keep counting.
    try require(a.status.sealedRecords == 10 && b.status.openedRecords == 10, "session totals")
}

func checkRekeyByBytesAndTime() throws {
    let (a, b) = try pair(try .init(records: 1000, bytes: 1000, seconds: 0))
    var seen: [UInt32] = []
    for _ in 0..<6 {
        let record = try a.seal(Data(repeating: 1, count: 400), context: context())
        seen.append(generation(record)); _ = try b.open(record, expecting: context())
    }
    try require(seen == [0, 0, 1, 1, 2, 2], "two 400-byte records per 1000-byte generation: \(seen)")
    let clock = Clock()
    let (c, d) = try pair(try .init(records: 1000, bytes: 1 << 20, seconds: 600), clock: clock)
    var timed: [UInt32] = []
    for step in 0..<5 {
        if step == 2 || step == 4 { clock.advance(seconds: 600) }
        let record = try c.seal(Data([UInt8(step)]), context: context())
        timed.append(generation(record)); _ = try d.open(record, expecting: context())
        if step == 0 { clock.advance(seconds: 599) }
    }
    try require(timed == [0, 0, 1, 1, 2], "a generation older than ten minutes is replaced: \(timed)")
}

func checkRekeyRefusals() throws {
    let policy = try ClusterRecordRekeyPolicy(records: 2, bytes: 1 << 20, seconds: 0)
    // A policy larger than the per-generation limits is refused.
    try refuses(ClusterRecordError.invalidConfiguration, "policy beyond limits") {
        _ = try pair(try .init(records: 2000, bytes: 1 << 20, seconds: 0))
    }
    // Skipping a generation (replaying the third record first) is refused and poisons.
    do {
        let (a, b) = try pair(policy)
        let r0 = try a.seal(Data([0]), context: context()); _ = try a.seal(Data([1]), context: context())
        let r2 = try a.seal(Data([2]), context: context())
        try require(generation(r2) == 1, "third record is generation 1")
        _ = try b.open(r0, expecting: context())
        try refusesAny("out of order") { _ = try b.open(r2, expecting: context()) }
        try require(!b.status.active, "poisoned after out-of-order record")
    }
    // A forged next generation fails to open under the derived key and poisons.
    do {
        let (a, b) = try pair(policy)
        var r0 = try a.seal(Data([0]), context: context()); _ = try b.open(r0, expecting: context())
        r0 = try a.seal(Data([1]), context: context())
        r0[23] ^= 1 // claims generation 1 one record early
        try refusesAny("forged rotation") { _ = try b.open(r0, expecting: context()) }
        try require(!b.status.active && b.status.receiveGeneration <= 1, "forged rotation poisons")
    }
    // A channel without a policy never accepts a nonzero generation.
    do {
        let (a, b) = try pair(nil)
        var record = try a.seal(Data([0]), context: context()); record[23] = 1
        try refuses(ClusterRecordError.unexpectedRecord, "generation without a policy") { _ = try b.open(record, expecting: context()) }
        let fresh = try pair(nil)
        let plain = try fresh.0.seal(Data([5]), context: context())
        try require(generation(plain) == 0 && Data(plain[20..<24]) == Data(count: 4), "no policy: header bytes unchanged")
    }
    // The old generation's records cannot be replayed after a rotation.
    do {
        let (a, b) = try pair(policy)
        let r0 = try a.seal(Data([0]), context: context()); let r1 = try a.seal(Data([1]), context: context())
        let r2 = try a.seal(Data([2]), context: context())
        _ = try b.open(r0, expecting: context()); _ = try b.open(r1, expecting: context()); _ = try b.open(r2, expecting: context())
        try refuses(ClusterRecordError.sequenceMismatch, "replay after rotation") { _ = try b.open(r1, expecting: context()) }
    }
    // Ends with different policies derive different keys.
    do {
        let k = SymmetricKey(data: Data(repeating: 9, count: 32))
        let a = try ClusterAuthenticatedRecordChannel(sessionKey: k, binding: binding(), localRank: 0, limits: limits(), rekey: policy)
        let b = try ClusterAuthenticatedRecordChannel(sessionKey: k, binding: binding(), localRank: 1, limits: limits(),
            rekey: try .init(records: 3, bytes: 1 << 20, seconds: 0))
        try refuses(ClusterRecordError.authenticationFailed, "policy mismatch") {
            _ = try b.open(try a.seal(Data([1]), context: context()), expecting: context())
        }
    }
}

func checkTamperReplayWrongKey() throws {
    let policy = try ClusterRecordRekeyPolicy(records: 100, bytes: 1 << 19, seconds: 600)
    for offset in [0, 7, 15, 19, 20, 23, 24, 30, 63] {
        let (a, b) = try pair(policy)
        var record = try a.seal(Data(repeating: 4, count: 24), context: context())
        record[offset] ^= 0x10
        try refusesAny("tamper at \(offset)") { _ = try b.open(record, expecting: context()) }
        try require(!b.status.active && b.status.openedRecords == 0, "tamper poisons without publishing")
    }
    do {
        let (a, b) = try pair(policy)
        let record = try a.seal(Data([1, 2, 3]), context: context())
        _ = try b.open(record, expecting: context())
        try refuses(ClusterRecordError.sequenceMismatch, "replay") { _ = try b.open(record, expecting: context()) }
    }
    do {
        let (a, _) = try pair(policy, key: 9)
        let (_, other) = try pair(policy, key: 10)
        try refuses(ClusterRecordError.authenticationFailed, "wrong key") {
            _ = try other.open(try a.seal(Data([1]), context: context()), expecting: context())
        }
    }
    do {
        let (a, b) = try pair(policy)
        try refuses(ClusterRecordError.unexpectedRecord, "wrong record kind") {
            _ = try b.open(try a.seal(Data([1]), context: context(.tokenRelay)), expecting: context(.handoffState))
        }
    }
}

// MARK: Pinned key exchange

final class Frames: @unchecked Sendable {
    private let lock = NSLock(); private var queues: [[Data]] = [[], []]
    var tamperNext: ((Data) -> Data)?
    func send(_ bytes: Data, from rank: Int) {
        lock.withLock {
            let value = tamperNext.map { f in tamperNext = nil; return f(bytes) } ?? bytes
            queues[1 - rank].append(value)
        }
    }
    func receive(_ rank: Int) throws -> Data {
        try lock.withLock {
            guard !queues[rank].isEmpty else { throw DataPlaneCheckError.failed("no frame") }
            return queues[rank].removeFirst()
        }
    }
}
final class MemoryIO: ClusterRecordByteIO, @unchecked Sendable {
    let localRank: Int; let worldSize = 2; let maximumFrameBytes = 4096 + 40; let frames: Frames
    init(_ rank: Int, _ frames: Frames) { localRank = rank; self.frames = frames }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws { try check(); frames.send(bytes, from: localRank) }
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
        try check(); let value = try frames.receive(localRank)
        guard value.count == byteCount else { throw DataPlaneCheckError.failed("frame size") }
        return value
    }
}

struct Members {
    let identities = [P256.Signing.PrivateKey(), P256.Signing.PrivateKey()]
    var pins: [ClusterDataPlanePin] { identities.map { ClusterDataPlanePin($0.publicKey) } }
    func credential(_ rank: Int, epoch e: UUID = epoch, pin: ClusterDataPlanePin? = nil) throws -> ClusterDataPlaneCredential {
        try .issue(identity: identities[rank], epoch: e, rank: rank, peerPin: pin ?? pins[1 - rank])
    }
}

/// Runs the exchange both ranks run, in one process.
func exchange(_ a: ClusterDataPlaneKeyExchange, _ b: ClusterDataPlaneKeyExchange, helloToB: ((Data) -> Data)? = nil,
              tagToA: ((Data) -> Data)? = nil) throws {
    let tagA = try a.accept(peerHello: b.hello)
    let tagB = try b.accept(peerHello: helloToB.map { $0(a.hello) } ?? a.hello)
    try b.confirm(peerTag: tagA)
    try a.confirm(peerTag: tagToA.map { $0(tagB) } ?? tagB)
}

func checkPinnedExchange() throws {
    let members = Members()
    let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
    let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
    try require(a.hello.count == 384 && b.hello.count == 384, "fixed hello size")
    try refuses(ClusterDataPlaneTrustError.inactive, "tensor-parallel seal keys before confirmation") {
        _ = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
            .tensorParallelSealKeys(scope: Data(repeating: 7, count: 32))
    }
    try exchange(a, b)
    // The tensor-parallel seal keys: one per direction, the same on both
    // ranks seen from each side, once per session.
    let agreed = Data(repeating: 7, count: 32)
    let ka = try a.tensorParallelSealKeys(scope: agreed), kb = try b.tensorParallelSealKeys(scope: agreed)
    func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    try require(bytes(ka.send) == bytes(kb.receive) && bytes(ka.receive) == bytes(kb.send)
        && bytes(ka.send) != bytes(ka.receive) && bytes(ka.send).count == 32,
        "tensor-parallel seal keys: one per direction, agreed by both ranks")
    try refuses(ClusterDataPlaneTrustError.inactive, "tensor-parallel seal keys derived twice") {
        _ = try a.tensorParallelSealKeys(scope: agreed)
    }
    let frames = Frames()
    let l = try ClusterRecordLimits(maximumPlaintextBytes: 4096)
    let (ta, ra) = try a.makeTransport(io: MemoryIO(0, frames), limits: l, rekey: .dataPlane)
    let (tb, rb) = try b.makeTransport(io: MemoryIO(1, frames), limits: l, rekey: .dataPlane)
    try require(ra.transcriptSHA256 == rb.transcriptSHA256 && ra.edgeID == rb.edgeID, "both ranks hold one transcript and edge")
    try require(ra.peerVerified && rb.peerVerified && ra.peerIdentitySHA256 == members.pins[1].sha256, "peer verified against its pin")
    let expectation = try ClusterRecordTransferExpectation(context: context(), length: .exact(5))
    try ta.send(Data([1, 2, 3, 4, 5]), expecting: expectation, check: {})
    try require(try tb.receive(expecting: expectation, check: {}) == Data([1, 2, 3, 4, 5]), "keyed transport carries a record")
    try tb.send(Data([9, 8, 7, 6, 5]), expecting: expectation, check: {})
    try require(try ta.receive(expecting: expectation, check: {}) == Data([9, 8, 7, 6, 5]), "both directions")
    // A tampered record on the keyed transport poisons it.
    frames.tamperNext = { var d = $0; d[30] ^= 1; return d }
    try ta.send(Data([1, 1, 1, 1, 1]), expecting: expectation, check: {})
    try refusesAny("tampered keyed record") { _ = try tb.receive(expecting: expectation, check: {}) }
    try require(!tb.status.active, "receiver poisoned")
    // Once only.
    try refuses(ClusterDataPlaneTrustError.inactive, "transport made twice") {
        _ = try a.makeTransport(io: MemoryIO(0, Frames()), limits: l, rekey: nil)
    }
    // A second session between the same members has another transcript.
    let a2 = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
    let b2 = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
    try exchange(a2, b2)
    let (_, r2) = try a2.makeTransport(io: MemoryIO(0, Frames()), limits: l, rekey: nil)
    try require(r2.transcriptSHA256 != ra.transcriptSHA256 && r2.edgeID == ra.edgeID, "fresh keys per session, same edge")
}

func checkPinRefusals() throws {
    let members = Members(), stranger = P256.Signing.PrivateKey()
    // Rank 1 pins someone else: rank 0's hello is refused before any key.
    do {
        let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
        let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1, pin: ClusterDataPlanePin(stranger.publicKey)), scopeSHA256: scope)
        try refuses(ClusterDataPlaneTrustError.peerNotPinned, "wrong pin") { _ = try b.accept(peerHello: a.hello) }
        try refuses(ClusterDataPlaneTrustError.inactive, "refused exchange stays closed") { _ = try b.accept(peerHello: a.hello) }
    }
    // An impostor that copies the pinned identity but certifies its own worker key with another identity.
    do {
        let impostorWorker = P256.Signing.PrivateKey()
        let forgedCertificate = try ClusterDataPlaneCertificate.sign(identity: stranger, epoch: epoch, rank: 0,
            workerSigningPublicKey: impostorWorker.publicKey.x963Representation)
        try refuses(ClusterDataPlaneTrustError.certificateRejected, "forged certificate at the credential") {
            _ = try ClusterDataPlaneCredential(epoch: epoch, rank: 0, workerSigningKey: impostorWorker.rawRepresentation,
                workerCertificate: forgedCertificate, memberIdentity: members.pins[0].identityPublicKey,
                peerPin: members.pins[1].identityPublicKey)
        }
        // On the wire: a genuine hello with the certificate swapped.
        let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
        let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        var hello = a.hello; hello.replaceSubrange(186..<250, with: forgedCertificate)
        try refuses(ClusterDataPlaneTrustError.certificateRejected, "forged certificate on the wire") { _ = try b.accept(peerHello: hello) }
    }
    // A hello whose agreement key was replaced (man in the middle) fails its signature.
    do {
        let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
        let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        var hello = a.hello
        hello.replaceSubrange(250..<282, with: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        try refuses(ClusterDataPlaneTrustError.helloSignatureRejected, "substituted agreement key") { _ = try b.accept(peerHello: hello) }
    }
    // Another epoch, another scope, the same rank: refused as the wrong peer.
    do {
        let other = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0, epoch: other), scopeSHA256: scope)
        let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        try refuses(ClusterDataPlaneTrustError.wrongPeer, "wrong epoch") { _ = try b.accept(peerHello: a.hello) }
        let c = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: Data(repeating: 1, count: 32))
        let d = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        try refuses(ClusterDataPlaneTrustError.wrongPeer, "wrong scope") { _ = try d.accept(peerHello: c.hello) }
        let e = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        let f = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        try refuses(ClusterDataPlaneTrustError.wrongPeer, "same rank") { _ = try f.accept(peerHello: e.hello) }
    }
    // A hello replayed from an earlier session passes the pin but not key confirmation.
    do {
        let old = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
        let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
        let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        _ = try a.accept(peerHello: b.hello)
        _ = try b.accept(peerHello: old.hello) // the attacker cannot answer for the old agreement key
        let tagA = try NativeTrafficKeyDerivationProbe.anyTag()
        try refuses(ClusterDataPlaneTrustError.keyConfirmationFailed, "replayed hello") { try b.confirm(peerTag: tagA) }
    }
    // A corrupted key-confirmation tag is refused.
    do {
        let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
        let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
        try refuses(ClusterDataPlaneTrustError.keyConfirmationFailed, "corrupted confirmation") {
            try exchange(a, b, tagToA: { var t = $0; t[0] ^= 1; return t })
        }
    }
    // Malformed hellos.
    do {
        let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
        let mutations: [(inout Data) -> Void] = [{ $0[0] ^= 1 }, { $0[4] = 2 }, { $0[383] = 1 }, { $0.removeLast() }]
        for mutate in mutations {
            let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
            var hello = a.hello; mutate(&hello)
            try refuses(ClusterDataPlaneTrustError.invalidHello, "malformed hello") { _ = try b.accept(peerHello: hello) }
        }
    }
}

// MARK: Qualification rekey interval and the status line

func checkQualificationRekeyAndStatusLine() throws {
    // Only `records:<n>`, canonical, 2...262144; byte and age limits stay the data plane's.
    let policy = try ClusterRecordRekeyPolicy.qualification("records:2")
    try require(policy.records == 2 && policy.bytes == ClusterRecordRekeyPolicy.dataPlane.bytes
        && policy.seconds == ClusterRecordRekeyPolicy.dataPlane.seconds, "records only")
    try require(try ClusterRecordRekeyPolicy.qualification("records:262144") == .dataPlane, "the data plane's own interval")
    for text in ["records:1", "records:262145", "records:064", "records:+64", "records:", "records:64:1", "bytes:64",
                 "Records:64", "records: 64", "64", ""] {
        try refuses(ClusterRecordError.invalidConfiguration, "qualification rekey '\(text)'") {
            _ = try ClusterRecordRekeyPolicy.qualification(text)
        }
    }
    // Both ranks keyed with it: one session crosses generations both ways, and
    // each rank's status line mirrors its peer's.
    let members = Members()
    let a = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
    let b = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
    try exchange(a, b)
    let frames = Frames(), l = try ClusterRecordLimits(maximumPlaintextBytes: 4096)
    let (ta, _) = try a.makeTransport(io: MemoryIO(0, frames), limits: l, rekey: policy)
    let (tb, _) = try b.makeTransport(io: MemoryIO(1, frames), limits: l, rekey: policy)
    for index in 0..<7 {
        let payload = Data(repeating: UInt8(index), count: 10 + index)
        let expectation = try ClusterRecordTransferExpectation(context: context(), length: .exact(payload.count))
        try ta.send(payload, expecting: expectation, check: {})
        try require(try tb.receive(expecting: expectation, check: {}) == payload, "rank 0 to 1 across generations")
        if index < 3 {
            try tb.send(payload, expecting: expectation, check: {})
            try require(try ta.receive(expecting: expectation, check: {}) == payload, "rank 1 to 0 across generations")
        }
    }
    try require(ta.status.codec.sendGeneration == 3 && tb.status.codec.receiveGeneration == 3, "7 records: generation 3")
    try require(tb.status.codec.sendGeneration == 1 && ta.status.codec.receiveGeneration == 1, "3 records: generation 1")
    try require(ta.status.lineFields == "active=1 sealed_records=7 opened_records=3 sealed_bytes=91 opened_bytes=33"
        + " send_generation=3 receive_generation=1", "status line fields: \(ta.status.lineFields)")
    try require(tb.status.lineFields == "active=1 sealed_records=3 opened_records=7 sealed_bytes=33 opened_bytes=91"
        + " send_generation=1 receive_generation=3", "peer's status line mirrors")
    // One rank keyed with another interval: the first record is refused and poisons it.
    let c = try ClusterDataPlaneKeyExchange(credential: members.credential(0), scopeSHA256: scope)
    let d = try ClusterDataPlaneKeyExchange(credential: members.credential(1), scopeSHA256: scope)
    try exchange(c, d)
    let mixed = Frames()
    let (tc, _) = try c.makeTransport(io: MemoryIO(0, mixed), limits: l, rekey: policy)
    let (td, _) = try d.makeTransport(io: MemoryIO(1, mixed), limits: l, rekey: .dataPlane)
    let expectation = try ClusterRecordTransferExpectation(context: context(), length: .exact(3))
    try tc.send(Data([1, 2, 3]), expecting: expectation, check: {})
    try refusesAny("intervals differ") { _ = try td.receive(expecting: expectation, check: {}) }
    try require(!td.status.active && td.status.lineFields.hasPrefix("active=0 "), "poisoned, and the line says so")
}

enum NativeTrafficKeyDerivationProbe {
    static func anyTag() throws -> Data { Data(repeating: 0x5a, count: 32) }
}

@main
struct DataPlaneChecks {
    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let groups: [(String, () throws -> Void)] = [
            ("rekey by record count, both ends follow, directions independent", checkRekeyByRecords),
            ("rekey by bytes and by age", checkRekeyByBytesAndTime),
            ("rekey refusals: skip, forged rotation, no policy, replay, policy mismatch", checkRekeyRefusals),
            ("tamper, replay, wrong key, wrong record kind", checkTamperReplayWrongKey),
            ("pinned exchange: one transcript, keyed records both ways, tamper poisons, once only", checkPinnedExchange),
            ("pin refusals: wrong pin, forged certificate, substituted key, wrong epoch/scope/rank, replayed hello, bad tag, malformed", checkPinRefusals),
            ("qualification rekey interval: refusals, keyed transport crosses generations, status lines mirror, mismatch refused", checkQualificationRekeyAndStatusLine),
        ]
        for (label, body) in groups {
            do { try body() } catch { print("FAIL " + label + ": \(error)"); throw error }
            print("PASS " + label)
        }
        print("PASS 7 data-plane rekey and pinned-exchange CPU groups; no native/network qualification")
    }
}
