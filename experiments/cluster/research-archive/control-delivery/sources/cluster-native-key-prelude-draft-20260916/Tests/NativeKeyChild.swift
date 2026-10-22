import Darwin
import Foundation
@testable import DarkbloomClusterBootstrap
@testable import DarkbloomClusterSecurity

func nativeKeyChild() throws {
    signal(SIGALRM) { _ in _exit(90) }; alarm(4)
    let args = CommandLine.arguments
    try requireNative(args.count == 7, "child arguments")
    let mode = args[2], path = args[3], ownerPID = Int32(args[4])!, rank = Int(args[5])!, until = UInt64(args[6])!
    let start = try fixtureStarts()[rank]
    let identity = try ClusterBootstrapIdentity(membershipEpoch: start.common.epoch, rank: rank)
    if mode == "wrong-owner" {
        try rejectNative("wrong owner PID accepted") { _ = try ClusterBootstrapConnection.connect(path: path,
            ownerProcessID: ownerPID, identity: identity, deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1) }
        print("PASS native child"); return
    }
    let connection = try ClusterBootstrapConnection.connect(path: path, ownerProcessID: ownerPID,
        identity: identity, deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
    defer { connection.cancel() }
    if mode == "wrong-child" || mode == "wrong-start" {
        try rejectNative("unbound start accepted") { _ = try connection.beginNativeKeyPrelude(expecting: start.canonicalBytes) }
        print("PASS native child"); return
    }
    if mode == "premature-mesh" {
        try rejectNative("mesh before prelude") { _ = try connection.exchange(sequence: 0, contribution: Data([1])) }
        print("PASS native child"); return
    }
    let context = try connection.beginNativeKeyPrelude(expecting: start.canonicalBytes)
    let authority = try ClusterNativeRecordAuthority(ownedPrelude: context)
    defer { authority.invalidate() }
    try requireNative(String(describing: authority) == "ClusterNativeRecordAuthority(redacted)" &&
        String(reflecting: authority) == "ClusterNativeRecordAuthority(redacted)" &&
        Mirror(reflecting: authority).children.isEmpty, "authority description exposes state")
    if ["cancel", "concurrent", "duplicate-context"].contains(mode) {
        let completion = NativeFixtureCompletion()
        DispatchQueue.global().async {
            do { _ = try authority.establish(); completion.finish(NativeFixtureFailure.failed("cancelled establish succeeded")) }
            catch { completion.finish(error) }
        }
        _ = try readNativeFixture(.standardInput, count: 1) // Parent already observed the real hello.
        if mode == "cancel" { authority.invalidate() }
        else if mode == "concurrent" { try rejectNative("concurrent establish accepted") { _ = try authority.establish() } }
        else { try rejectNative("duplicate context accepted") { _ = try ClusterNativeRecordAuthority(ownedPrelude: context) } }
        let failure = try completion.wait()
        try requireNative(failure is ClusterNativeKeyError, "cancel returned no closed failure")
        try rejectNative("cancelled holder reused") { _ = try authority.establish() }
        print("PASS native child"); return
    }
    if ["deadline", "substitution", "reflection", "low-order", "binding-mismatch"].contains(mode) {
        try rejectNative("invalid key establishment succeeded") { _ = try authority.establish() }
        try rejectNative("failed holder made transport") { _ = try authority.makeRecordTransport(io: NativeFixtureByteIO(rank: rank)) }
        print("PASS native child"); return
    }
    let receipt = try authority.establish()
    try requireNative(receipt.rank == rank && receipt.epoch == start.common.epoch &&
        receipt.localPublicKey.count == 32 && receipt.peerPublicKey.count == 32 && receipt.transcriptSHA256.count == 32,
        "public receipt binding")
    let local = Data([UInt8(rank + 1)])
    let mesh = try connection.exchange(sequence: 0, contribution: local)
    try requireNative(mesh == Data([1, 2]), "protected mesh transition")
    if mode == "expired-factory" {
        while DispatchTime.now().uptimeNanoseconds <= until { usleep(1000) }
        try rejectNative("expired factory accepted") { _ = try authority.makeRecordTransport(io: NativeFixtureByteIO(rank: rank)) }
        print("PASS native child"); return
    }
    if mode == "wrong-io" {
        try rejectNative("wrong rank IO accepted") { _ = try authority.makeRecordTransport(io: NativeFixtureByteIO(rank: 1-rank)) }
        print("PASS native child"); return
    }
    let transport = try authority.makeRecordTransport(io: NativeFixtureByteIO(rank: rank))
    let expected = try ClusterRecordTransferExpectation(context: .init(requestID: nil, type: .loadAgreement,
        expectationSHA256: Data(repeating: 7, count: 32)), length: .exact(3))
    let own = rank == 0 ? Data([1, 2, 3]) : Data([4, 5, 6]), peer = rank == 0 ? Data([4, 5, 6]) : Data([1, 2, 3])
    if rank == 0 { try transport.send(own, expecting: expected, check: {}) }
    let observed = try transport.receive(expecting: expected, check: {})
    try requireNative(observed == peer, "native-owned derived keys differ")
    if rank == 1 { try transport.send(own, expecting: expected, check: {}) }
    try requireNative(transport.status.active && transport.status.codec.sealedRecords == 1 &&
        transport.status.codec.openedRecords == 1, "actual protected fixture records")
    if mode == "cancel-after-factory" { context.cancel() }
    else if mode == "duplicate-after-factory" {
        try rejectNative("context reused after factory") { _ = try ClusterNativeRecordAuthority(ownedPrelude: context) }
    } else { try rejectNative("second factory accepted") { _ = try authority.makeRecordTransport(io: NativeFixtureByteIO(rank: rank)) } }
    try requireNative(!transport.status.active, "authority cancellation failed to poison transport")
    print("PASS native child")
}
