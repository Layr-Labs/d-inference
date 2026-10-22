import Darwin
import Foundation
@testable import DarkbloomClusterBootstrap
@testable import DarkbloomClusterSecurity

func nativeDeadline(_ milliseconds: UInt64 = 2500) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
}
func readNativeFixture(_ handle: FileHandle, count: Int) throws -> Data {
    var bytes = Data()
    while bytes.count < count {
        let part = try handle.read(upToCount: count - bytes.count) ?? Data()
        guard !part.isEmpty else { throw NativeFixtureFailure.failed("fixture EOF") }
        bytes.append(part)
    }
    return bytes
}
final class NativeFixtureCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)
    func finish(_ error: Error?) { lock.withLock { failure = error }; done.signal() }
    func wait() throws -> Error? {
        try requireNative(done.wait(timeout: .now() + 1) == .success, "native cancellation did not join")
        return lock.withLock { failure }
    }
}

/// Test-only byte IO over the already-owned child's pipes. No RDMA or native
/// allocation is claimed. Only ciphertext is relayed by the parent fixture.
final class NativeFixtureByteIO: ClusterRecordByteIO {
    let localRank: Int
    let worldSize = 2
    let maximumFrameBytes = 4136
    init(rank: Int) { localRank = rank }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {
        try check(); try requireNative(bytes.count == 43, "fixture ciphertext size")
        try FileHandle.standardOutput.write(contentsOf: bytes); try check()
    }
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
        try check(); try requireNative(byteCount == 43, "fixture receive size")
        let bytes = try readNativeFixture(.standardInput, count: byteCount); try check(); return bytes
    }
}

final class NativeFixtureChild {
    let process = Process()
    let input = Pipe(), output = Pipe(), diagnostics = Pipe()
    let listener: ClusterBootstrapListener
    let start: ClusterNativeAuthorizationStart
    let deadline: UInt64
    var connection: ClusterBootstrapConnection?
    var owner: ClusterOwnerPreludeContext?
    private var started = false
    init(mode: String, rank: Int, deadline: UInt64, ownerPID: Int32 = getpid()) throws {
        self.deadline = deadline; start = try fixtureStarts()[rank]
        listener = try .init(deadlineUptimeNanoseconds: deadline)
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--child", mode, listener.socketPath, String(ownerPID), String(rank), String(deadline)]
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        try process.run(); started = true
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? diagnostics.fileHandleForWriting.close()
    }
    deinit {
        connection?.cancel()
        try? input.fileHandleForWriting.close()
        // Child self-alarm is independent of this parent; no signal to a reaped
        // PID. The outer owned helper also bounds the entire fixture process.
        if started { process.waitUntilExit() }
    }
    func connect(expectedPID: Int32? = nil, transmittedStart: Data? = nil) throws {
        let identity = try ClusterBootstrapIdentity(membershipEpoch: start.common.epoch, rank: start.rank)
        let channel = try listener.accept(processID: expectedPID ?? process.processIdentifier,
            identity: identity, deadlineUptimeNanoseconds: deadline, mode: .nativeKeyPreludeV1)
        connection = channel
        owner = try channel.beginOwnerKeyPrelude(start: transmittedStart ?? start.canonicalBytes)
    }
    func signalAction() throws { try input.fileHandleForWriting.write(contentsOf: Data([1])) }
    func relayFrame(to peer: NativeFixtureChild) throws {
        let frame = try readNativeFixture(output.fileHandleForReading, count: 43)
        try peer.input.fileHandleForWriting.write(contentsOf: frame)
    }
    func finish() throws {
        process.waitUntilExit()
        let error = try diagnostics.fileHandleForReading.readToEnd() ?? Data()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        try requireNative(process.terminationReason == .exit && process.terminationStatus == 0, "native child assertion/timeout failed")
        try requireNative(error.isEmpty && result == Data("PASS native child\n".utf8), "unexpected child output")
    }
}
