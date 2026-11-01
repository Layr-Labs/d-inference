import CryptoKit
import Dispatch
import Foundation

enum AdapterFixtureError: Error { case assertion(String), noFrame, cancelled }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw AdapterFixtureError.assertion(message) }
}
func refuses(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw AdapterFixtureError.assertion("Expected refusal")
}

final class FixtureFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [[Data]] = [[], []]
    private var sent: [[Int]] = [[], []]
    private var received: [[Int]] = [[], []]
    func send(_ bytes: Data, from rank: Int) {
        lock.lock(); defer { lock.unlock() }
        incoming[1 - rank].append(bytes); sent[rank].append(bytes.count)
    }
    func receive(_ count: Int, rank: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        received[rank].append(count)
        guard !incoming[rank].isEmpty else { throw AdapterFixtureError.noFrame }
        return incoming[rank].removeFirst()
    }
    func transformFirst(rank: Int, _ body: (Data) -> Data) {
        lock.lock(); defer { lock.unlock() }; incoming[rank][0] = body(incoming[rank][0])
    }
    func first(rank: Int) -> Data {
        lock.lock(); defer { lock.unlock() }; return incoming[rank][0]
    }
    func inject(_ bytes: Data, rank: Int) {
        lock.lock(); defer { lock.unlock() }; incoming[rank].append(bytes)
    }
    func sends(_ rank: Int) -> [Int] { lock.lock(); defer { lock.unlock() }; return sent[rank] }
    func receives(_ rank: Int) -> [Int] { lock.lock(); defer { lock.unlock() }; return received[rank] }
}

final class FixtureByteIO: ClusterRecordByteIO, @unchecked Sendable {
    let localRank: Int
    let worldSize = 2
    let maximumFrameBytes: Int
    let frames: FixtureFrames
    let entered: DispatchSemaphore?
    let resume: DispatchSemaphore?
    init(_ rank: Int, frames: FixtureFrames, ceiling: Int, blockReceive: Bool = false) {
        localRank = rank; self.frames = frames; maximumFrameBytes = ceiling
        entered = blockReceive ? .init(value: 0) : nil
        resume = blockReceive ? .init(value: 0) : nil
    }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {
        try check(); frames.send(bytes, from: localRank); try check()
    }
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
        try check()
        if let entered, let resume {
            entered.signal()
            guard resume.wait(timeout: .now() + 2) == .success else { throw AdapterFixtureError.cancelled }
        }
        let bytes = try frames.receive(byteCount, rank: localRank)
        try check(); return bytes
    }
}

struct FixturePair: Sendable {
    let frames: FixtureFrames
    let first: ClusterAuthenticatedRecordTransport
    let second: ClusterAuthenticatedRecordTransport
    let secondIO: FixtureByteIO
    init(blockReceive: Bool = false) throws {
        let frames = FixtureFrames()
        // Public test bytes only. This is not coordinator membership evidence.
        let key = SymmetricKey(data: Data(repeating: 0x63, count: 32))
        let binding = try ClusterRecordBinding(epoch: UUID(), planSHA256: Data(repeating: 0x21, count: 32),
            membershipTranscriptSHA256: Data(repeating: 0x42, count: 32))
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: 1024)
        let io0 = FixtureByteIO(0, frames: frames, ceiling: 1064)
        let io1 = FixtureByteIO(1, frames: frames, ceiling: 1064, blockReceive: blockReceive)
        self.frames = frames; secondIO = io1
        first = try .init(sessionKey: key, binding: binding, limits: limits, io: io0)
        second = try .init(sessionKey: key, binding: binding, limits: limits, io: io1)
    }
}

func expectation(_ length: ClusterRecordTransferLength, type: ClusterRecordType = .residualPayload,
                 metadata: UInt8 = 0x31) throws -> ClusterRecordTransferExpectation {
    let setup = [.keyConfirmation, .loadAgreement, .loadedReady].contains(type)
    let context = try ClusterRecordContext(requestID: setup ? nil : UUID(uuidString: "cd3363bd-778a-4415-bc5a-f31d935463d5")!,
        type: type, expectationSHA256: Data(repeating: metadata, count: 32))
    return try .init(context: context, length: length)
}

final class FixtureOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var returned = false
    private var failed = false
    func success() { lock.lock(); returned = true; lock.unlock() }
    func failure() { lock.lock(); failed = true; lock.unlock() }
    var wasRefused: Bool { lock.lock(); defer { lock.unlock() }; return failed && !returned }
}
