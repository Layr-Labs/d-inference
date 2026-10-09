import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import Foundation

/// One rank's worker, reached through a command that carries its standard
/// streams: a local shell for rank 0, `ssh` for rank 1. It plugs into the
/// library's `ClusterWorkerPair`, which owns the request protocol.
///
/// This endpoint never signals anything. "Native cleanup" here means closing
/// the worker's input and waiting for the process to end by itself: a worker
/// that loses its input releases its model and exits, and one blocked in a
/// native call ends at the lifetime it was started with. The library's own
/// `ClusterWorkerProcess` terminates and then kills its child two seconds
/// after a fence, which a qualification run on a loaded model must not do.
public final class PairWorkerEndpoint: ClusterWorkerEndpoint, @unchecked Sendable {
    public struct Termination: Equatable, Sendable {
        public let status: Int32
        public let signalled: Bool
    }

    public let expectedIdentity: ClusterWorkerIdentity
    public let expectedProfile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String
    private let lifetimeNanoseconds: UInt64
    private let process = Process()
    private let input = Pipe(), output = Pipe(), diagnostics = Pipe()
    private let lock = NSLock()
    private let arrivals = DispatchSemaphore(value: 0)
    private let exited = DispatchGroup()
    private let streams = DispatchGroup()
    private let writer: DispatchQueue
    private let notifications = DispatchQueue(label: "darkbloom.pair-check.invalidation")
    private var incoming: [ClusterWorkerEventFrame] = []
    private var nextCommand: UInt64 = 0
    private var nextEvent: UInt64 = 0
    private var readyValue: ClusterWorkerReady?
    private var readyAt: UInt64?
    private var fault: ClusterWorkerOwnerError?
    private var inputClosed = false
    private var handler: (@Sendable () -> Void)?
    private var notified = false
    private var launchedAt: UInt64?
    private var preamble: PairLaunchPreamble?
    private var preambleAt: UInt64?
    private var terminationValue: Termination?
    private var stderrTail = Data()
    private var stderrLine = Data()
    private var eventLog: [String] = []
    private var tokenEvents = 0
    private var shutdownSent = false
    private var shutdownComplete = false
    private var admittedValue: Bool?
    private var refusalValue: String?

    public init(command: [String], expectedIdentity: ClusterWorkerIdentity, rank: Int, profile: ClusterWorkerProfile,
                executionPlanSHA256: String, lifetimeSeconds: Int) throws {
        // Validates the identity, rank, profile and plan the way a worker does.
        _ = try ClusterWorkerSession(identity: expectedIdentity, rank: rank, profile: profile,
                                     executionPlanSHA256: executionPlanSHA256)
        guard let executable = command.first, executable.hasPrefix("/"), (10...300).contains(lifetimeSeconds) else {
            throw ClusterWorkerOwnerError.invalid("Invalid pair worker launch")
        }
        self.expectedIdentity = expectedIdentity; self.rank = rank; expectedProfile = profile
        self.executionPlanSHA256 = executionPlanSHA256
        lifetimeNanoseconds = UInt64(lifetimeSeconds) * 1_000_000_000
        writer = DispatchQueue(label: "darkbloom.pair-check.writer.\(rank)")
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = PairConfiguration.transportEnvironment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ClusterWorkerOwnerError.invalid("Cannot suppress pipe SIGPIPE")
        }
    }

    // MARK: Observations for the report

    public var launched: Bool { lock.withLock { launchedAt != nil } }
    public var termination: Termination? { lock.withLock { terminationValue } }
    public var readySeconds: Double? {
        lock.withLock { zip2(launchedAt, readyAt).map { Double($1 - $0) / 1e9 } }
    }
    public var requestCapacityBytes: Int? { lock.withLock { readyValue?.requestCapacityBytes ?? capacityAtReady } }
    private var capacityAtReady: Int?
    public var events: [String] {
        lock.withLock { eventLog.map { $0 == "committedToken" ? "committedToken x\(tokenEvents)" : $0 } }
    }
    public var shutdownCommandSent: Bool { lock.withLock { shutdownSent } }
    public var shutdownCompleteObserved: Bool { lock.withLock { shutdownComplete } }
    public var admitted: Bool? { lock.withLock { admittedValue } }
    public var refusal: String? { lock.withLock { refusalValue } }
    public var readyObserved: Bool { lock.withLock { readyAt != nil } }
    public var diagnosticTail: String {
        let text = String(decoding: lock.withLock { stderrTail }, as: UTF8.self)
        return text.split(separator: "\n").filter { !$0.hasPrefix(PairLaunchPreamble.marker) }.joined(separator: "\n")
    }
    /// The worker's process ID on its own Mac, once its launch line arrived.
    public var workerProcessID: Int32? { lock.withLock { preamble?.processID } }
    public var faultDescription: String? { lock.withLock { fault.map { "\($0)" } } }

    private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    // MARK: Launch and streams

    public func launch() throws {
        try lock.withLock {
            guard launchedAt == nil, fault == nil else { throw ClusterWorkerOwnerError.invalid("Worker launched twice") }
            exited.enter(); streams.enter(); streams.enter()
            process.terminationHandler = { [self] process in
                // The streams end when the process does; drain what it last wrote.
                _ = streams.wait(timeout: .now() + 2)
                let notify = lock.withLock { () -> (@Sendable () -> Void)? in
                    terminationValue = .init(status: process.terminationStatus,
                                             signalled: process.terminationReason == .uncaughtSignal)
                    readyValue = nil
                    return notificationLocked()
                }
                exited.leave(); arrivals.signal()
                if let notify { notifications.async(execute: notify) }
            }
            // Taken before the child exists, so it is never later than the
            // moment the child reads its own clock.
            let started = DispatchTime.now().uptimeNanoseconds
            do { try process.run() } catch {
                fault = .closed; exited.leave(); streams.leave(); streams.leave()
                throw error
            }
            launchedAt = started
        }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()
        Thread.detachNewThread { [self] in readEvents(); streams.leave() }
        Thread.detachNewThread { [self] in readDiagnostics(); streams.leave() }
    }

    /// Waits for the launch line that carries the worker's clock.
    public func waitForLaunchLine(until deadline: UInt64) -> Bool {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if lock.withLock({ preamble != nil }) { return true }
            if nativeCleanupObserved { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func readEvents() {
        var decoder = ClusterWorkerLineDecoder(commandStream: false)
        let descriptor = output.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: ClusterWorkerLineDecoder.readChunkBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                if count == 0, (try? decoder.finish()) == nil { fail(.invalid("Partial worker record at end of stream")) }
                return
            }
            do {
                for line in try decoder.append(Data(buffer.prefix(count))) { try accept(ClusterWorkerCodec.decodeEvent(line)) }
            } catch {
                // Keep draining so the worker never blocks on a full pipe.
                fail(.invalid("Invalid worker output: \(error)"))
                decoder = ClusterWorkerLineDecoder(commandStream: false)
            }
        }
    }

    private func readDiagnostics() {
        let descriptor = diagnostics.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.withLock {
                stderrTail.append(contentsOf: buffer.prefix(count))
                if stderrTail.count > 16_384 { stderrTail.removeFirst(stderrTail.count - 16_384) }
                guard preamble == nil, stderrLine.count < 4096 else { return }
                for byte in buffer.prefix(count) {
                    if byte != 10 { stderrLine.append(byte); continue }
                    if let value = PairLaunchPreamble(line: String(decoding: stderrLine, as: UTF8.self)) {
                        preamble = value; preambleAt = now; break
                    }
                    stderrLine.removeAll()
                }
            }
        }
    }

    private func accept(_ frame: ClusterWorkerEventFrame) throws {
        let notify = try lock.withLock { () -> (@Sendable () -> Void)? in
            guard frame.membershipEpoch == expectedIdentity.membershipEpoch, frame.sequence == nextEvent else {
                throw ClusterWorkerOwnerError.invalid("Worker event epoch or sequence differs")
            }
            if case .ready(let ready) = frame.event {
                guard nextEvent == 0, ready.identity == expectedIdentity, ready.rank == rank,
                      ready.profile == expectedProfile, ready.executionPlanSHA256 == executionPlanSHA256 else {
                    throw ClusterWorkerOwnerError.invalid("Worker readiness differs from the expected identity, profile or plan")
                }
                readyValue = ready; capacityAtReady = ready.requestCapacityBytes
                readyAt = DispatchTime.now().uptimeNanoseconds
            } else if nextEvent == 0 { throw ClusterWorkerOwnerError.invalid("Worker event precedes readiness") }
            guard incoming.count < 64 else { throw ClusterWorkerOwnerError.invalid("Worker event queue exceeded bound") }
            incoming.append(frame); nextEvent += 1
            switch frame.event {
            case .ready: eventLog.append("ready")
            case .admitted: eventLog.append("admitted"); admittedValue = true
            case .refused(let reason): eventLog.append("refused:\(reason.rawValue)"); admittedValue = false; refusalValue = reason.rawValue
            case .committedToken:
                if tokenEvents == 0 { eventLog.append("committedToken") }
                tokenEvents += 1
            case .finished(let reason): eventLog.append("finished:\(reason.rawValue)")
            case .retired(let outcome): eventLog.append("retired:\(outcome.rawValue)")
            case .failed(let reason): eventLog.append("failed:\(reason.rawValue)")
            case .unavailable(let reason): eventLog.append("unavailable:\(reason.rawValue)")
            case .shutdownComplete: eventLog.append("shutdownComplete"); shutdownComplete = true
            }
            switch frame.event {
            case .unavailable, .failed: readyValue = nil; return notificationLocked()
            default: return nil
            }
        }
        arrivals.signal()
        if let notify { notifications.async(execute: notify) }
    }

    private func fail(_ error: ClusterWorkerOwnerError) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            if fault == nil { fault = error }
            readyValue = nil
            return notificationLocked()
        }
        closeInput()
        arrivals.signal()
        if let notify { notifications.async(execute: notify) }
    }

    /// All call sites hold the lock.
    private func notificationLocked() -> (@Sendable () -> Void)? {
        guard !notified, let handler else { return nil }
        notified = true; return handler
    }

    /// End of input, after anything already queued for the worker.
    private func closeInput() {
        lock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            writer.async { [self] in try? input.fileHandleForWriting.close() }
        }
    }

    // MARK: ClusterWorkerEndpoint

    public var readiness: ClusterWorkerReady? { lock.withLock { fault == nil && !inputClosed ? readyValue : nil } }
    public var nativeCleanupObserved: Bool { lock.withLock { terminationValue != nil || (launchedAt == nil && fault != nil) } }

    /// On this Mac's clock, never later than the worker's own deadline: the
    /// worker started its lifetime after this process started the launch.
    public var localLifetimeDeadlineUptimeNanoseconds: UInt64 {
        lock.withLock { (launchedAt ?? DispatchTime.now().uptimeNanoseconds) + lifetimeNanoseconds }
    }

    public func setInvalidationHandler(_ value: @escaping @Sendable () -> Void) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            handler = value
            return fault != nil || inputClosed || terminationValue != nil ? notificationLocked() : nil
        }
        if let notify { notifications.async(execute: notify) }
    }

    /// A reservation deadline is an absolute time on the worker's own clock.
    /// The launch line gave one reading of that clock, taken between this
    /// process starting the launch and reading the line, so the difference
    /// between the clocks is known to within that interval. The earlier bound
    /// is used and the result is capped at the worker's own deadline.
    func workerDeadline(forLocal deadline: UInt64) throws -> UInt64 {
        try lock.withLock {
            guard let preamble, let preambleAt else { throw ClusterWorkerOwnerError.unavailable }
            let offset = Int64(bitPattern: preamble.uptimeNanoseconds) - Int64(bitPattern: preambleAt)
            let translated = Int64(bitPattern: deadline) + offset
            guard translated > 0 else { throw ClusterWorkerOwnerError.deadline }
            return min(UInt64(translated), preamble.deadlineUptimeNanoseconds)
        }
    }

    public func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        var translated = command
        if case .reserve(let value) = command {
            translated = .reserve(.init(profileID: value.profileID, promptTokenIDs: value.promptTokenIDs,
                stopTokenIDs: value.stopTokenIDs, outputCount: value.outputCount, chunkSize: value.chunkSize,
                deadlineUptimeNanoseconds: try workerDeadline(forLocal: value.deadlineUptimeNanoseconds),
                capacityLimitBytes: value.capacityLimitBytes))
        }
        try lock.withLock {
            guard launchedAt != nil, terminationValue == nil, fault == nil, !inputClosed else { throw ClusterWorkerOwnerError.closed }
            guard deadline > DispatchTime.now().uptimeNanoseconds else { throw ClusterWorkerOwnerError.deadline }
            let frame = ClusterWorkerCommandFrame(membershipEpoch: expectedIdentity.membershipEpoch,
                sequence: nextCommand, requestID: requestID, command: translated)
            let bytes = try ClusterWorkerCodec.encode(frame)
            nextCommand += 1
            if case .shutdown = command { shutdownSent = true }
            // Queued while the lock is held, so bytes leave in sequence order.
            writer.async { [self] in
                do { try input.fileHandleForWriting.write(contentsOf: bytes) } catch { fail(.closed) }
            }
        }
    }

    public func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        while true {
            if cancelled() { throw ClusterWorkerOwnerError.cancelled }
            if let event = lock.withLock({ incoming.isEmpty ? nil : incoming.removeFirst() }) { return event }
            if let error = lock.withLock({ fault }) { throw error }
            if nativeCleanupObserved { throw ClusterWorkerOwnerError.closed }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
            _ = arrivals.wait(timeout: .init(uptimeNanoseconds: min(deadline, now + 50_000_000)))
        }
    }

    /// Withdraws the worker by ending its input. No signal is sent.
    public func requestNativeCleanup() {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            if fault == nil && terminationValue == nil && !shutdownSent { fault = .closed }
            readyValue = nil
            return notificationLocked()
        }
        closeInput()
        arrivals.signal()
        if let notify { notifications.async(execute: notify) }
    }

    public func waitForNativeCleanup() { if launched { exited.wait() } }
    public func waitUntilNativeCleanup() async {
        guard launched else { return }
        await withCheckedContinuation { continuation in exited.notify(queue: .global()) { continuation.resume() } }
    }

    /// For the driver's bounded final wait; `false` means the exit was not seen.
    public func waitForExit(until deadline: UInt64) -> Bool {
        guard launched else { return true }
        return exited.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success
    }
}
