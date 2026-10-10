import Foundation
import Darwin
import DarkbloomClusterProtocol

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ClusterWorkerOwnerError.invalid(message) }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private final class Tokens: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    private var complete = false
    func accept(_ event: ClusterWorkerRequestEvent) -> Bool {
        lock.withLock {
            if case .token(let id) = event { ids.append(id) }
            if case .finished(.length) = event { complete = true }
        }; return true
    }
    var passed: Bool { lock.withLock { ids == Array(9..<137) && complete } }
}

@main struct PumpWakeupCheck {
    static func main() async throws {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(30)
        try kernelWakeAndCoalescing(); try concurrentDrain(); try closeAndFDReuse()
        try await commandProgress(URL(fileURLWithPath: CommandLine.arguments[1]))
        print("{\"passed\":true,\"groups\":4,\"realKernelPoll\":true,\"actualOwnedChildren\":true,\"nativeModelOrNetwork\":false}")
        alarm(0)
    }
    static func kernelWakeAndCoalescing() throws {
        let wake = try WorkerPumpWakeup(); defer { wake.closeAfterPolling() }
        try require(fcntl(wake.readDescriptor, F_GETFL) & O_NONBLOCK != 0
            && fcntl(wake.readDescriptor, F_GETFD) & FD_CLOEXEC != 0, "Wakeup FD flags differ")
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async {
            usleep(20_000)
            for _ in 0..<10_000 { wake.signal() }
            done.leave()
        }
        var descriptor = pollfd(fd: wake.readDescriptor, events: Int16(POLLIN), revents: 0)
        let count = Darwin.poll(&descriptor, 1, 2_000)
        try require(count == 1 && descriptor.revents & Int16(POLLIN) != 0, "Signal did not wake actual kernel poll")
        try require(done.wait(timeout: .now() + 2) == .success, "Nonblocking/coalesced signal stalled")
        try require(wake.drain(), "Wake drain failed")
        descriptor.revents = 0
        try require(Darwin.poll(&descriptor, 1, 0) == 0, "Repeated signals accumulated beyond one byte")
        try require(wake.signal(), "Signal after drain failed")
        try require(Darwin.poll(&descriptor, 1, 0) == 1 && wake.drain(), "Drain lost rearmed wakeup")
    }
    static func concurrentDrain() throws {
        let wake = try WorkerPumpWakeup(); defer { wake.closeAfterPolling() }
        let counter = Counter(), group = DispatchGroup()
        for _ in 0..<4 {
            group.enter(); DispatchQueue.global().async {
                for _ in 0..<1_000 { counter.increment(); wake.signal() }
                group.leave()
            }
        }
        while counter.count < 4_000 {
            var descriptor = pollfd(fd: wake.readDescriptor, events: Int16(POLLIN), revents: 0)
            try require(Darwin.poll(&descriptor, 1, 2_000) > 0 && wake.drain(), "Concurrent update wakeup lost")
        }
        try require(group.wait(timeout: .now() + 2) == .success, "Producers did not finish")
        try require(wake.drain(), "Final coalesced drain failed")
    }
    static func closeAndFDReuse() throws {
        let wake = try WorkerPumpWakeup(), oldRead = wake.readDescriptor
        let group = DispatchGroup(), began = DispatchSemaphore(value: 0)
        for _ in 0..<4 {
            group.enter(); DispatchQueue.global().async {
                began.signal()
                for _ in 0..<10_000 { wake.signal() }
                group.leave()
            }
        }
        began.wait()
        // No poll is active here. Producers may still be signaling while the
        // pump-owned close serializes with them, then the FD numbers are reused.
        wake.closeAfterPolling()
        var replacement: [Int32] = [-1, -1]
        try require(Darwin.pipe(&replacement) == 0, "Replacement pipe failed")
        defer { for fd in replacement { Darwin.close(fd) } }
        try require(replacement[0] == oldRead, "Fixture did not exercise read-FD reuse")
        try require(fcntl(replacement[0], F_SETFL, O_NONBLOCK) == 0, "Replacement nonblocking failed")
        try require(group.wait(timeout: .now() + 3) == .success, "Signal/close race stalled")
        for _ in 0..<100 { try require(!wake.signal(), "Closed wakeup accepted a signal") }
        var byte: UInt8 = 0
        try require(Darwin.read(replacement[0], &byte, 1) == -1 && errno == EAGAIN, "Late signal wrote to reused FD")
        byte = 9
        try require(Darwin.write(replacement[1], &byte, 1) == 1 && !wake.drain(), "Closed drain touched new FD")
        byte = 0
        try require(Darwin.read(replacement[0], &byte, 1) == 1 && byte == 9, "Closed drain consumed unrelated bytes")
        wake.closeAfterPolling() // Idempotent; replacement descriptors stay open.
        try require(fcntl(replacement[0], F_GETFD) >= 0, "Repeated close touched reused FD")
    }
    static func commandProgress(_ executable: URL) async throws {
        let now = DispatchTime.now().uptimeNanoseconds, lifetime = now + 15_000_000_000
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), "normal"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 3_000_000_000, lifetimeDeadline: lifetime)
        }
        defer { for worker in workers { worker.fence() } }
        for worker in workers { try worker.launch() }
        let pair = try ClusterWorkerPair(workers: workers, startupDeadline: now + 3_000_000_000)
        let request = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
            promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 128, chunkSize: 2,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 4_000_000_000, capacityLimitBytes: 1800))
        let captured = Tokens()
        try request.start { captured.accept($0) }; await request.waitUntilRetired()
        request.releaseResources()
        let passed = captured.passed && request.bytesInUse == 0
        await pair.shutdown()
        try require(passed && workers.allSatisfy(\.nativeCleanupObserved), "128 sequential decisions hit idle-poll delays or cleanup failed")
    }
}
