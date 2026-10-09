import Darwin
import Foundation
@testable import DarkbloomClusterBootstrap
@testable import DarkbloomClusterSecurity

enum TestFailure: Error { case failed(String) }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw TestFailure.failed(message) }
}
func reject(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is TestFailure { throw TestFailure.failed(message) } catch { return }
    throw TestFailure.failed(message)
}
func deadline(_ milliseconds: UInt64 = 3000) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
}
func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func unhex(_ string: String) -> Data {
    var data = Data(); var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}

@main enum PreludeCheck {
    static let epoch = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
    static func identity(_ rank: Int) throws -> ClusterBootstrapIdentity { try .init(membershipEpoch: epoch, rank: rank) }

    static func main() {
        do {
            if CommandLine.arguments.count > 1 { try child(); return }
            try codecVectors()
            try fullTwoRankExchange()
            try refusalGroups()
            print(#"{"passed":true,"groups":3,"actualChildren":8,"modelExecution":false,"networkUsed":false,"rdma":false}"#)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    // MARK: - Fixture construction

    static func makeStarts() throws -> (common: ClusterNativeAuthorizationCommon, starts: [ClusterNativeAuthorizationStart], bytes: [Data]) {
        func digest(_ label: String) -> Data { Data(SHA256.hash(data: Data(label.utf8))) }
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64,
            maximumCumulativePlaintextBytesPerDirection: 262_144)
        let common = try ClusterNativeAuthorizationCommon(epoch: epoch, membershipGeneration: 7, nativePolicyGeneration: 11,
            membershipTranscriptSHA256: digest("membership"), approvedNativeBindingSHA256: digest("binding"),
            planSHA256: digest("plan"), artifactSHA256: digest("artifact"), nativeRuntimeSHA256: digest("runtime"),
            capabilitySHA256: digest("capability"), resourcePolicySHA256: digest("resource"), profileSHA256: digest("profile"),
            schedule: .oneChunkLookahead, maximumTransportFrameBytes: 4136, limits: limits)
        var starts: [ClusterNativeAuthorizationStart] = []
        for rank in 0...1 {
            starts.append(try ClusterNativeAuthorizationStart(common: common, rank: rank,
                ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID()))
        }
        return (common, starts, starts.map { $0.canonicalBytes })
    }

    static func spawn(_ listener: ClusterBootstrapListener, mode: String, rank: Int,
                      until: UInt64, startHex: String, extra: String = "") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [mode, listener.socketPath, String(getpid()), String(rank), String(until), startHex, extra]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); return process
    }

    static func reap(_ process: Process) throws {
        let limit = deadline(5000)
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < limit { usleep(1000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw TestFailure.failed("child required fixture fence") }
        process.waitUntilExit()
        try require(process.terminationReason == .exit && process.terminationStatus == 0, "child did not finish its asserted path")
    }

    // MARK: - Child paths (actual native-side processes)

    static func child() throws {
        signal(SIGALRM) { _ in _exit(99) }; alarm(10)
        let args = CommandLine.arguments, mode = args[1], path = args[2]
        let owner = Int32(args[3])!, rank = Int(args[4])!, until = UInt64(args[5])!
        let startBytes = unhex(args[6]), extra = args.count > 7 ? args[7] : ""
        let connection = try ClusterBootstrapConnection.connect(path: path, ownerProcessID: owner,
            identity: identity(rank), deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
        switch mode {
        case "native":
            let context = try connection.beginNativeKeyPrelude(expecting: startBytes)
            let authority = try ClusterNativeRecordAuthority(ownedPrelude: context)
            let receipt = try authority.establish()
            try require(receipt.rank == rank && receipt.transcriptSHA256.count == 32, "receipt malformed")
            return
        case "wrong-start":
            var wrong = startBytes; wrong[wrong.count - 1] ^= 1
            try reject("wrong expected start admitted") { _ = try connection.beginNativeKeyPrelude(expecting: wrong) }
            return
        case "mesh-early":
            _ = try connection.beginNativeKeyPrelude(expecting: startBytes)
            try reject("mesh exchange ran during incomplete prelude") {
                _ = try connection.exchange(sequence: 0, contribution: Data([1, 2, 3, 4]))
            }
            return
        case "second-claim":
            let context = try connection.beginNativeKeyPrelude(expecting: startBytes)
            try context.claimNativeKeyHolder {}
            try reject("second key-holder claim admitted") { try context.claimNativeKeyHolder {} }
            return
        case "cancel-mid":
            // The owner cancels us mid-exchange; establish must fail, never hang.
            let context = try connection.beginNativeKeyPrelude(expecting: startBytes)
            let authority = try ClusterNativeRecordAuthority(ownedPrelude: context)
            try reject("establish survived owner cancellation") { _ = try authority.establish() }
            return
        case "bad-peer-tag":
            // extra carries nothing; the owner fabricates the peer confirmation.
            let context = try connection.beginNativeKeyPrelude(expecting: startBytes)
            let authority = try ClusterNativeRecordAuthority(ownedPrelude: context)
            try reject("forged peer confirmation admitted") { _ = try authority.establish() }
            _ = extra
            return
        default:
            throw TestFailure.failed("unknown child mode \(mode)")
        }
    }

    // MARK: - Group 1: codec vectors mirror the Go/Swift/Python public bytes

    static func codecVectors() throws {
        // Values mirror darkbloom-platform coordinator/tests/protocol/testdata/native_pair_public_vector.json
        // fields common/starts (same closed canonical encoding).
        func digest32(_ i: Int) -> Data { Data(SHA256.hash(data: Data("fixture-native-field-\(i)".utf8))) }
        var epochBytes = Data((1...16).map { UInt8($0) })
        let epoch = UUID(uuid: (epochBytes[0], epochBytes[1], epochBytes[2], epochBytes[3],
                                epochBytes[4], epochBytes[5], epochBytes[6], epochBytes[7],
                                epochBytes[8], epochBytes[9], epochBytes[10], epochBytes[11],
                                epochBytes[12], epochBytes[13], epochBytes[14], epochBytes[15]))
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64,
            maximumCumulativePlaintextBytesPerDirection: 262_144)
        let common = try ClusterNativeAuthorizationCommon(epoch: epoch, membershipGeneration: 7, nativePolicyGeneration: 11,
            membershipTranscriptSHA256: digest32(0), approvedNativeBindingSHA256: digest32(1),
            planSHA256: digest32(2), artifactSHA256: digest32(3), nativeRuntimeSHA256: digest32(4),
            capabilitySHA256: digest32(5), resourcePolicySHA256: digest32(6), profileSHA256: digest32(7),
            schedule: .oneChunkLookahead, maximumTransportFrameBytes: 4136, limits: limits)
        let expectedCommon = "6461726b626c6f6f6d2f6e61746976652d617574686f72697a6174696f6e2f636f6d6d6f6e2f7631000102030405060708090a0b0c0d0e0f100000000000000007000000000000000b8ad475855361fdea5e55d4d25a1509a8bd642b6cd46b833911de616f35c259a216ae2c7dc747fc8ce4e9689e4a452ff4521715b2df90080271ccb8fb1cf621af23446f275f5bf8db1c3800edec9b9894e100ab11c066e2da3801b2ee8ec4e858115aeb8857c13d5ecd6019cee9924c70594c1b672a31f77b87794f22db84a7f3e4f23a1c268daffa06314ca0ed8e9750fc8993c955059c388fe2bd927ff669f6185fdc937e1cbcf6020851084ceafbdb4cb5e72b7d4fe7cad2fdd2e69161bc6a0b991f35b02833b15fd09df7db00e02a2f94f79457a156267d94fe7e415bff0e6c652e1114a1a09c419b0a491336f41b5ffbb58187b877c1b702b1945ac6c168010102000010280000100000000000000000400000000000040000"
        try require(hex(common.canonicalBytes) == expectedCommon, "common bytes diverged from Go/Python vector")
        // Round-trip through the exact-count decoder; trailing bytes are refused.
        let decoded = try ClusterNativeAuthorizationStart(encoded: try ClusterNativeAuthorizationStart(
            common: common, rank: 0, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID()).canonicalBytes)
        try require(decoded.rank == 0, "start round trip lost rank")
        try reject("trailing bytes admitted") {
            _ = try ClusterNativeAuthorizationStart(encoded: common.canonicalBytes + Data([0]))
        }
        epochBytes = Data()
    }

    // MARK: - Group 2: full two-rank authenticated exchange over actual children

    static func fullTwoRankExchange() throws {
        let (_, _, startBytes) = try makeStarts()
        let until = deadline(8000)
        let listener0 = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
        let listener1 = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
        let child0 = try spawn(listener0, mode: "native", rank: 0, until: until, startHex: hex(startBytes[0]))
        let child1 = try spawn(listener1, mode: "native", rank: 1, until: until, startHex: hex(startBytes[1]))
        let owner0 = try listener0.accept(processID: child0.processIdentifier, identity: identity(0),
            deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
        let owner1 = try listener1.accept(processID: child1.processIdentifier, identity: identity(1),
            deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
        let prelude0 = try owner0.beginOwnerKeyPrelude(start: startBytes[0])
        let prelude1 = try owner1.beginOwnerKeyPrelude(start: startBytes[1])
        let hello0 = try prelude0.receiveHello(), hello1 = try prelude1.receiveHello()
        let binding = try ClusterNativeKeyBinding(hellos: [
            try ClusterNativeKeyHello(encoded: hello0), try ClusterNativeKeyHello(encoded: hello1)])
        try prelude0.sendBinding(binding.canonicalBytes)
        try prelude1.sendBinding(binding.canonicalBytes)
        let tag0 = try prelude0.receiveConfirmation(), tag1 = try prelude1.receiveConfirmation()
        try prelude0.sendPeerConfirmation(tag1)
        try prelude1.sendPeerConfirmation(tag0)
        try prelude0.requireComplete(transcriptSHA256: binding.transcriptSHA256)
        try prelude1.requireComplete(transcriptSHA256: binding.transcriptSHA256)
        try reap(child0); try reap(child1)
    }

    // MARK: - Group 3: refusal groups

    static func refusalGroups() throws {
        let (_, _, startBytes) = try makeStarts()
        // Wrong expected start never enters the exchange.
        do {
            let until = deadline()
            let listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let child = try spawn(listener, mode: "wrong-start", rank: 0, until: until, startHex: hex(startBytes[0]))
            let owner = try listener.accept(processID: child.processIdentifier, identity: identity(0),
                deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
            let prelude = try owner.beginOwnerKeyPrelude(start: startBytes[0])
            try reject("owner observed start agreement") { _ = try prelude.receiveHello() }
            try reap(child)
        }
        // Mesh operations are refused while the prelude is incomplete.
        do {
            let until = deadline()
            let listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let child = try spawn(listener, mode: "mesh-early", rank: 0, until: until, startHex: hex(startBytes[0]))
            let owner = try listener.accept(processID: child.processIdentifier, identity: identity(0),
                deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
            let prelude = try owner.beginOwnerKeyPrelude(start: startBytes[0])
            try reject("owner read after poisoned mesh attempt") { _ = try prelude.receiveHello() }
            try reap(child)
        }
        // A second key-holder claim poisons the socket.
        do {
            let until = deadline()
            let listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let child = try spawn(listener, mode: "second-claim", rank: 0, until: until, startHex: hex(startBytes[0]))
            let owner = try listener.accept(processID: child.processIdentifier, identity: identity(0),
                deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
            let prelude = try owner.beginOwnerKeyPrelude(start: startBytes[0])
            try reap(child)
            prelude.cancel()
        }
        // Owner cancellation interrupts a blocked establish.
        do {
            let until = deadline()
            let listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let child = try spawn(listener, mode: "cancel-mid", rank: 0, until: until, startHex: hex(startBytes[0]))
            let owner = try listener.accept(processID: child.processIdentifier, identity: identity(0),
                deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
            let prelude = try owner.beginOwnerKeyPrelude(start: startBytes[0])
            usleep(50_000)
            prelude.cancel()
            try reap(child)
        }
        // A fabricated peer confirmation tag fails HMAC verification natively.
        do {
            let until = deadline()
            let listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let child = try spawn(listener, mode: "bad-peer-tag", rank: 0, until: until, startHex: hex(startBytes[0]))
            let owner = try listener.accept(processID: child.processIdentifier, identity: identity(0),
                deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
            let prelude = try owner.beginOwnerKeyPrelude(start: startBytes[0])
            _ = try prelude.receiveHello()
            // The owner's binding here is deliberately invalid for this single
            // native; the exchange must fail before any transport exists.
            try prelude.sendBinding(Data(repeating: 7, count: 64))
            try reap(child)
        }
        // Owner-side transcript mismatch refuses completion.
        do {
            let until = deadline()
            let listener0 = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let listener1 = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let child0 = try spawn(listener0, mode: "native", rank: 0, until: until, startHex: hex(startBytes[0]))
            let child1 = try spawn(listener1, mode: "native", rank: 1, until: until, startHex: hex(startBytes[1]))
            let owner0 = try listener0.accept(processID: child0.processIdentifier, identity: identity(0),
                deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
            let owner1 = try listener1.accept(processID: child1.processIdentifier, identity: identity(1),
                deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
            let prelude0 = try owner0.beginOwnerKeyPrelude(start: startBytes[0])
            let prelude1 = try owner1.beginOwnerKeyPrelude(start: startBytes[1])
            let hello0 = try prelude0.receiveHello(), hello1 = try prelude1.receiveHello()
            let binding = try ClusterNativeKeyBinding(hellos: [
                try ClusterNativeKeyHello(encoded: hello0), try ClusterNativeKeyHello(encoded: hello1)])
            try prelude0.sendBinding(binding.canonicalBytes)
            try prelude1.sendBinding(binding.canonicalBytes)
            let tag0 = try prelude0.receiveConfirmation(), tag1 = try prelude1.receiveConfirmation()
            try prelude0.sendPeerConfirmation(tag1)
            try prelude1.sendPeerConfirmation(tag0)
            try reject("owner accepted a fabricated transcript") {
                try prelude0.requireComplete(transcriptSHA256: Data(SHA256.hash(data: Data("forged".utf8))))
            }
            prelude0.cancel(); prelude1.cancel()
            try reap(child0); try reap(child1)
        }
    }
}

import CryptoKit
