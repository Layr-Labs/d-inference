import CryptoKit
import Darwin
import Foundation
@testable import DarkbloomClusterBootstrap
@testable import DarkbloomClusterSecurity

func nativePairCheck(mode: String) throws {
    let until = nativeDeadline(mode == "expired-factory" ? 500 : 2500)
    let children = try [NativeFixtureChild(mode: mode, rank: 0, deadline: until),
                        NativeFixtureChild(mode: mode, rank: 1, deadline: until)]
    defer { children.forEach { $0.connection?.cancel() } }
    for child in children { try child.connect() }
    let hellos = try children.map { try ClusterNativeKeyHello(encoded: $0.owner!.receiveHello()) }
    let binding = try ClusterNativeKeyBinding(hellos: hellos)
    for child in children { try child.owner!.sendBinding(binding.canonicalBytes) }
    let confirmations = try children.map { try $0.owner!.receiveConfirmation() }
    for rank in 0..<2 { try children[rank].owner!.sendPeerConfirmation(confirmations[mode == "reflection" ? rank : 1-rank]) }
    if mode == "reflection" {
        for child in children {
            try rejectNative("reflected confirmation completed") { try child.owner!.requireComplete(transcriptSHA256: binding.transcriptSHA256) }
            try child.finish()
        }
        return
    }
    for child in children { try child.owner!.requireComplete(transcriptSHA256: binding.transcriptSHA256) }
    let rounds = try children.map { try $0.connection!.receiveRound() }
    for rank in 0..<2 {
        try requireNative(rounds[rank].contribution == Data([UInt8(rank + 1)]), "mesh contribution")
        try children[rank].connection!.reply(to: rounds[rank], gathered: Data([1, 2]))
    }
    if mode != "wrong-io" && mode != "expired-factory" {
        try children[0].relayFrame(to: children[1]); try children[1].relayFrame(to: children[0])
    }
    for child in children { try child.finish() }
}

func nativeBlockedChecks() throws {
    for mode in ["cancel", "concurrent", "duplicate-context", "deadline"] {
        let child = try NativeFixtureChild(mode: mode, rank: 0, deadline: nativeDeadline(mode == "deadline" ? 250 : 2500))
        try child.connect(); _ = try child.owner!.receiveHello()
        if mode != "deadline" { try child.signalAction() }
        try child.finish()
        try rejectNative("failed native started mesh") { _ = try child.connection!.receiveRound() }
    }
}

func nativePeerChecks() throws {
    do {
        let child = try NativeFixtureChild(mode: "wrong-owner", rank: 0, deadline: nativeDeadline(), ownerPID: getpid() + 1)
        try child.finish()
    }
    do {
        let child = try NativeFixtureChild(mode: "wrong-child", rank: 0, deadline: nativeDeadline())
        try rejectNative("wrong native PID accepted") { try child.connect(expectedPID: child.process.processIdentifier + 1) }
        try child.finish()
    }
    do {
        let child = try NativeFixtureChild(mode: "wrong-start", rank: 0, deadline: nativeDeadline())
        try child.connect(transmittedStart: fixtureStarts()[1].canonicalBytes)
        try child.finish()
    }
    do {
        let child = try NativeFixtureChild(mode: "premature-mesh", rank: 0, deadline: nativeDeadline())
        // Merely accept the PID-bound socket; deliberately never send start.
        child.connection = try child.listener.accept(processID: child.process.processIdentifier,
            identity: .init(membershipEpoch: child.start.common.epoch, rank: 0),
            deadlineUptimeNanoseconds: child.deadline, mode: .nativeKeyPreludeV1)
        try child.finish()
        try rejectNative("owner mesh before prelude") { _ = try child.connection!.receiveRound() }
    }
}

func nativeSubstitutionChecks() throws {
    for mode in ["substitution", "low-order", "binding-mismatch"] {
        let child = try NativeFixtureChild(mode: mode, rank: 0, deadline: nativeDeadline())
        try child.connect()
        let actual = try ClusterNativeKeyHello(encoded: child.owner!.receiveHello())
        let peerStart = try fixtureStarts()[1]
        let peerKey = mode == "low-order" ? Data([1]) + Data(repeating: 0, count: 31) : Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let peer = try ClusterNativeKeyHello(start: peerStart, publicKey: peerKey)
        let own = mode == "substitution" ? try ClusterNativeKeyHello(start: actual.start,
            publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation) : actual
        var bytes = try ClusterNativeKeyBinding(hellos: [own, peer]).canonicalBytes
        if mode == "binding-mismatch" {
            let peerEpochByte = ClusterNativeKeyBinding.prefix.count + ClusterNativeKeyHello.encodedCount +
                ClusterNativeKeyHello.prefix.count + ClusterNativeAuthorizationStart.prefix.count +
                ClusterNativeAuthorizationCommon.domain.count
            bytes[peerEpochByte] ^= 1
        }
        try child.owner!.sendBinding(bytes)
        try child.finish()
    }
}

@main enum NativeKeyCheck {
    static func main() {
        do {
            if CommandLine.arguments.dropFirst().first == "--child" { try nativeKeyChild(); return }
            try requireNative(CommandLine.arguments.count == 2, "vector argument")
            try nativeValueChecks(vectorURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("PASS independent canonical/X25519/HKDF/confirmation vector and malformed values")
            try nativePeerChecks(); print("PASS actual parent/native PID and protected-start/mesh gates")
            try nativeBlockedChecks(); print("PASS actual socket cancellation/concurrent/context replay/deadline")
            try nativeSubstitutionChecks(); print("PASS actual public-key/local-binding/low-order substitution refusal")
            try nativePairCheck(mode: "reflection"); print("PASS actual bilateral confirmation reflection refusal")
            for mode in ["success", "cancel-after-factory", "duplicate-after-factory"] { try nativePairCheck(mode: mode) }
            print("PASS actual bilateral key agreement, encrypted fixture records, once-only factory/revocation")
            for mode in ["wrong-io", "expired-factory"] { try nativePairCheck(mode: mode) }
            print("PASS actual transport-rank binding and unchanged factory deadline")
            print("PASS 7 native-key CPU groups; 23 actual children; no model, RDMA, coordinator or native approval")
        } catch { fputs("FAIL native-key fixture: \(error)\n", stderr); exit(1) }
    }
}
