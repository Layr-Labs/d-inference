import Foundation
import Darwin
import DarkbloomClusterProtocol

public enum ClusterWorkerOwnerError: Error, Equatable, Sendable {
    case invalid(String), unavailable, deadline, cancelled, closed
}

/// Recorded by the direct-child supervisor, never inferred from a pipe event.
public enum ClusterWorkerProcessTermination: Equatable, Sendable {
    case launchFailed
    case exited(Int32)
    case signalled(Int32)
}

final class WorkerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var completed = false
    init() { group.enter() }
    var isComplete: Bool { lock.withLock { completed } }
    func complete() {
        let first = lock.withLock { if completed { return false }; completed = true; return true }
        if first { group.leave() }
    }
    func wait(until deadline: UInt64) -> Bool { group.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success }
    func wait() { group.wait() }
    func value() async { await withCheckedContinuation { c in group.notify(queue: .global()) { c.resume() } } }
}

/// When an owner may signal a direct child that has not ended itself.
///
/// A fence is cooperative first: the owner closes the child's command stream,
/// which a worker treats as the order to cancel its request, release its model
/// and exit. A signal ends the process without that release, so none is sent
/// until the child's own hard deadline has passed: the lifetime it was started
/// with, or its startup deadline when it was told one and never became ready.
/// SIGKILL follows SIGTERM only for a process that ignored both its own
/// deadline and SIGTERM; nothing else could return the device, and by then the
/// child's contract says it no longer runs.
public struct ClusterWorkerSignalPolicy: Sendable, Equatable {
    /// The child was given its startup deadline and exits there by itself.
    public let childEndsItselfAtStartupDeadline: Bool
    /// Wait after the child's own hard deadline before SIGTERM.
    public let terminateMarginNanoseconds: UInt64
    /// Wait after SIGTERM before SIGKILL.
    public let killMarginNanoseconds: UInt64
    /// Wait after SIGKILL before an owner stops waiting for the exit.
    public let reapMarginNanoseconds: UInt64

    public init(childEndsItselfAtStartupDeadline: Bool = false, terminateMarginNanoseconds: UInt64 = 5_000_000_000,
                killMarginNanoseconds: UInt64 = 10_000_000_000, reapMarginNanoseconds: UInt64 = 5_000_000_000) {
        self.childEndsItselfAtStartupDeadline = childEndsItselfAtStartupDeadline
        self.terminateMarginNanoseconds = terminateMarginNanoseconds
        self.killMarginNanoseconds = killMarginNanoseconds; self.reapMarginNanoseconds = reapMarginNanoseconds
    }

    public static let standard = ClusterWorkerSignalPolicy()
    /// Longest an owner waits past the child's lifetime for its observed exit.
    public var allowanceNanoseconds: UInt64 { terminateMarginNanoseconds + killMarginNanoseconds + reapMarginNanoseconds }
    var isBounded: Bool {
        [terminateMarginNanoseconds, killMarginNanoseconds, reapMarginNanoseconds].allSatisfy { $0 <= 60_000_000_000 }
    }
}

public struct ClusterWorkerLaunch: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
    }
}

/// Owns one direct child. Native workers must not spawn untracked descendants.
/// An event or a sent signal never completes observedExit; actual process exit does.
/// A fence closes the child's command stream and waits; see ClusterWorkerSignalPolicy
/// for the only conditions under which this owner signals the child.
public final class ClusterWorkerProcess: @unchecked Sendable {
    public let expectedIdentity: ClusterWorkerIdentity
    public let expectedProfile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String
    public let lifetimeDeadline: UInt64
    public let retirement: ClusterWorkerSignalPolicy
    private let process = Process()
    /// The child's exit as Foundation reports it; see `ClusterProcessExit`.
    private let childExit = ClusterProcessExit()
    private let input = Pipe(), output = Pipe(), diagnostics = Pipe()
    private let lock = NSLock()
    private let arrivals = DispatchSemaphore(value: 0)
    private let exited = WorkerCompletion()
    private let wakeup: WorkerPumpWakeup
    private var incoming: [ClusterWorkerEventFrame] = []
    private var outgoing: [(bytes: Data, offset: Int, deadline: UInt64)] = []
    private var queuedBytes = 0
    private var nextCommand: UInt64 = 0
    private var nextEvent: UInt64 = 0
    private var readyValue: ClusterWorkerReady?
    private var fault: ClusterWorkerOwnerError?
    private var fenceAt: UInt64?
    private var invalidated: (@Sendable () -> Void)?
    private var notificationSent = false
    private let notifications = DispatchQueue(label: "darkbloom.worker.invalidation")
    private var stderrTail = Data()
    private var stderrBytes = 0
    private let startupDeadline: UInt64
    private var launched = false
    private var terminalValue: ClusterWorkerProcessTermination?
    private var launchedPID: Int32?
    private var readyObserved = false
    private var signals: [Int32] = []
    public var launchedProcessIdentifier: Int32? { lock.withLock { launchedPID } }
    /// Signals this owner sent, in order. Empty when the child ended itself.
    public var sentSignals: [Int32] { lock.withLock { signals } }
    /// After this an owner stops waiting: the child outlived its own hard
    /// deadline, SIGTERM and SIGKILL, and its ownership cannot be resolved here.
    public var retirementDeadlineUptimeNanoseconds: UInt64 {
        let value = lifetimeDeadline.addingReportingOverflow(retirement.allowanceNanoseconds)
        return value.overflow ? UInt64.max : value.partialValue
    }
    public var termination: ClusterWorkerProcessTermination? { lock.withLock { terminalValue } }
    public var observedExit: Bool { exited.isComplete }
    public var readiness: ClusterWorkerReady? { lock.withLock { fault == nil && fenceAt == nil ? readyValue : nil } }
    public var diagnosticTail: Data { lock.withLock { stderrTail } }

    public init(launch: ClusterWorkerLaunch, expectedIdentity: ClusterWorkerIdentity, rank: Int,
                profile: ClusterWorkerProfile, executionPlanSHA256: String, startupDeadline: UInt64, lifetimeDeadline: UInt64,
                retirement: ClusterWorkerSignalPolicy = .standard) throws {
        _ = try ClusterWorkerSession(identity: expectedIdentity, rank: rank, profile: profile,
            executionPlanSHA256: executionPlanSHA256)
        let now = DispatchTime.now().uptimeNanoseconds
        guard launch.executable.isFileURL, launch.executable.path.hasPrefix("/"),
              launch.arguments.count <= 64, launch.arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              launch.environment.count <= 128,
              launch.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0")
                  && !$0.value.contains("\0") && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8192 }),
              startupDeadline > now, lifetimeDeadline >= startupDeadline, retirement.isBounded,
              lifetimeDeadline - now <= ClusterWorkerLimits.deadlineNanoseconds else {
            throw ClusterWorkerOwnerError.invalid("Invalid worker launch")
        }
        self.expectedIdentity = expectedIdentity; self.rank = rank; expectedProfile = profile
        self.executionPlanSHA256 = executionPlanSHA256; self.startupDeadline = startupDeadline
        self.lifetimeDeadline = lifetimeDeadline; self.retirement = retirement
        wakeup = try WorkerPumpWakeup()
        process.executableURL = launch.executable; process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        for handle in [input.fileHandleForWriting, output.fileHandleForReading, diagnostics.fileHandleForReading] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ClusterWorkerOwnerError.invalid("Cannot bound pipe IO") }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ClusterWorkerOwnerError.invalid("Cannot suppress pipe SIGPIPE")
        }
    }

    public func launch() throws {
        try lock.withLock {
            guard !launched else { throw ClusterWorkerOwnerError.invalid("Worker launched twice") }
            launched = true
            do { try childExit.run(process); launchedPID = process.processIdentifier } catch { fault = .closed; terminalValue = .launchFailed; exited.complete(); wakeup.closeAfterPolling(); throw error }
        }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? diagnostics.fileHandleForWriting.close()
        DispatchQueue(label: "darkbloom.worker.io.\(rank)").async { self.pump() }
    }

    public func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            invalidated = handler
            if fault != nil || fenceAt != nil || exited.isComplete || (nextEvent > 0 && readyValue == nil) { return notificationLocked() }
            return nil
        }
        if let notify { notifications.async(execute: notify) }
    }

    func send(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        try lock.withLock {
            guard launched, !exited.isComplete, fault == nil, fenceAt == nil else { throw ClusterWorkerOwnerError.closed }
            guard deadline > DispatchTime.now().uptimeNanoseconds else { throw ClusterWorkerOwnerError.deadline }
            let frame = ClusterWorkerCommandFrame(membershipEpoch: expectedIdentity.membershipEpoch,
                sequence: nextCommand, requestID: requestID, command: command)
            let bytes = try ClusterWorkerCodec.encode(frame)
            guard outgoing.count < 16, queuedBytes <= 1024 * 1024 - bytes.count else {
                throw ClusterWorkerOwnerError.invalid("Worker command queue exceeded bound")
            }
            outgoing.append((bytes, 0, deadline)); queuedBytes += bytes.count; nextCommand += 1
        }
        guard wakeup.signal() else { fail(.closed); throw ClusterWorkerOwnerError.closed }
    }

    func next(until deadline: UInt64, cancelled: () -> Bool = { false }) throws -> ClusterWorkerEventFrame {
        while true {
            if cancelled() { throw ClusterWorkerOwnerError.cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ClusterWorkerOwnerError.deadline }
            let found = lock.withLock { () -> ClusterWorkerEventFrame? in
                if incoming.isEmpty { return nil }; return incoming.removeFirst()
            }
            if let found { return found }
            if observedExit { throw ClusterWorkerOwnerError.closed }
            if let error = lock.withLock({ fault }) { throw error }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= lifetimeDeadline { fail(.deadline) }
            guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
            _ = arrivals.wait(timeout: .init(uptimeNanoseconds: min(deadline, now + 50_000_000)))
        }
    }

    /// Stops this owner's use of the child and closes its command stream. The
    /// child ends itself; this call sends no signal.
    public func fence() { fail(.closed) }
    public func waitUntilExited() async { await exited.value() }
    func waitForExit() { exited.wait() }
    /// False when the exit was not observed by `deadline`; ownership is retained.
    public func waitForExit(until deadline: UInt64) -> Bool { exited.wait(until: deadline) }

    private func fail(_ error: ClusterWorkerOwnerError) {
        let failure = lock.withLock { () -> (changed: Bool, notify: (@Sendable () -> Void)?) in
            if fault != nil { return (false, nil) }
            fault = error; fenceAt = DispatchTime.now().uptimeNanoseconds; outgoing.removeAll(); queuedBytes = 0
            return (true, notificationLocked())
        }
        if failure.changed { wakeup.signal() }
        arrivals.signal(); if let notify = failure.notify { notifications.async(execute: notify) }
    }

    /// All call sites hold lock. Notifications never run on the pipe pump.
    private func notificationLocked() -> (@Sendable () -> Void)? {
        guard !notificationSent, let invalidated else { return nil }
        notificationSent = true; return invalidated
    }

    private func publish(_ frame: ClusterWorkerEventFrame) throws {
        let notify = try lock.withLock { () -> (@Sendable () -> Void)? in
            guard frame.membershipEpoch == expectedIdentity.membershipEpoch, frame.sequence == nextEvent else {
                throw ClusterWorkerOwnerError.invalid("Worker event epoch or sequence differs")
            }
            if case .ready(let ready) = frame.event {
                guard nextEvent == 0, ready.identity == expectedIdentity, ready.rank == rank,
                      ready.profile == expectedProfile, ready.executionPlanSHA256 == executionPlanSHA256 else {
                    throw ClusterWorkerOwnerError.invalid("Worker readiness differs")
                }
                readyValue = ready; readyObserved = true
            } else if nextEvent == 0 { throw ClusterWorkerOwnerError.invalid("Worker event precedes readiness") }
            guard incoming.count < 32 else { throw ClusterWorkerOwnerError.invalid("Worker event queue exceeded bound") }
            incoming.append(frame); nextEvent += 1
            switch frame.event {
            case .unavailable, .failed: readyValue = nil; return notificationLocked()
            default: return nil
            }
        }
        arrivals.signal(); if let notify { notifications.async(execute: notify) }
    }

    private func pump() {
        var decoder = ClusterWorkerLineDecoder(commandStream: false)
        var stdoutOpen = true, stderrOpen = true, inputOpen = true
        var terminateSentAt: UInt64?, killSent = false
        var exitObservedAt: UInt64?
        var wakeupUsable = true
        let outFD = output.fileHandleForReading.fileDescriptor, errFD = diagnostics.fileHandleForReading.fileDescriptor
        let inFD = input.fileHandleForWriting.fileDescriptor
        defer {
            wakeup.closeAfterPolling()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? diagnostics.fileHandleForReading.close()
        }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= lifetimeDeadline { fail(.deadline) }
            if lock.withLock({ readyValue == nil && fault == nil && nextEvent == 0 }) && now >= startupDeadline { fail(.deadline) }
            if lock.withLock({ fenceAt }) != nil {
                // End of the command stream is the fence. A worker reads it as
                // the order to cancel, release its model and exit by itself.
                if inputOpen { try? input.fileHandleForWriting.close(); inputOpen = false }
                if process.isRunning {
                    // The child's own hard deadline: the last moment it has
                    // promised to still be running. No signal precedes it.
                    let own = lock.withLock { retirement.childEndsItselfAtStartupDeadline && !readyObserved ? startupDeadline : lifetimeDeadline }
                    if terminateSentAt == nil, now >= own, now - own >= retirement.terminateMarginNanoseconds {
                        process.terminate(); terminateSentAt = now; lock.withLock { signals.append(SIGTERM) }
                    }
                    if let sent = terminateSentAt, !killSent, now - sent >= retirement.killMarginNanoseconds {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL); killSent = true; lock.withLock { signals.append(SIGKILL) }
                    }
                }
            }
            var fds = [pollfd(fd: stdoutOpen ? outFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderrOpen ? errFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: !inputOpen || lock.withLock({ outgoing.isEmpty }) ? -1 : inFD, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: wakeupUsable ? wakeup.readDescriptor : -1, events: Int16(POLLIN), revents: 0)]
            let status = fds.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), 50) }
            if status < 0 && errno != EINTR { fail(.invalid("Worker poll failed")) }
            if fds[3].revents != 0 && !wakeup.drain() {
                wakeupUsable = false; fail(.invalid("Worker wakeup read failed"))
            }
            // A wake can arrive after the input-FD snapshot. Rebuild that
            // snapshot on the next iteration; no timeout reduction is needed.
            for index in 0..<2 where fds[index].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: ClusterWorkerLineDecoder.readChunkBytes)
                let count = Darwin.read(fds[index].fd, &bytes, bytes.count)
                if count > 0 {
                    do {
                        let data = Data(bytes.prefix(count))
                        if index == 0 { for line in try decoder.append(data) { try publish(ClusterWorkerCodec.decodeEvent(line)) } }
                        else {
                            try lock.withLock {
                                guard stderrBytes <= 1024 * 1024 - count else { throw ClusterWorkerOwnerError.invalid("Worker stderr exceeded bound") }
                                stderrBytes += count; stderrTail.append(data)
                                if stderrTail.count > 65_536 { stderrTail.removeFirst(stderrTail.count - 65_536) }
                            }
                        }
                    } catch {
                        fail(.invalid("Invalid or excessive worker output"))
                        if index == 0 { stdoutOpen = false } else { stderrOpen = false }
                    }
                } else if count == 0 {
                    if index == 0 { stdoutOpen = false; do { try decoder.finish() } catch { fail(.invalid("Partial worker record at EOF")) } }
                    else { stderrOpen = false }
                } else if errno != EAGAIN && errno != EINTR {
                    fail(.invalid("Worker pipe read failed")); if index == 0 { stdoutOpen = false } else { stderrOpen = false }
                }
            }
            if fds[2].revents != 0 {
                do {
                    try lock.withLock {
                        guard !outgoing.isEmpty else { return }
                        guard DispatchTime.now().uptimeNanoseconds < outgoing[0].deadline else { throw ClusterWorkerOwnerError.deadline }
                        let item = outgoing[0]
                        let count = item.bytes.withUnsafeBytes { bytes in
                            Darwin.write(inFD, bytes.baseAddress!.advanced(by: item.offset), min(65_536, bytes.count - item.offset))
                        }
                        if count > 0 {
                            outgoing[0].offset += count; queuedBytes -= count
                            if outgoing[0].offset == outgoing[0].bytes.count { outgoing.removeFirst() }
                        } else if count < 0 && errno != EAGAIN && errno != EINTR { throw ClusterWorkerOwnerError.closed }
                    }
                } catch { fail(.closed) }
            }
            // Charge blocked writes even when POLLOUT never arrives.
            if lock.withLock({ outgoing.first.map { DispatchTime.now().uptimeNanoseconds >= $0.deadline } ?? false }) { fail(.deadline) }
            if !process.isRunning {
                // The child is gone; Foundation's exit report follows, usually
                // within a tenth of a second. Wait for it in bounded steps so
                // this loop keeps its deadlines even if the report were lost:
                // waitUntilExit() could sleep here for ever, and the terminal
                // below, which is what lets the owner clear its journal, would
                // never be published.
                guard childExit.wait(untilUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000) else { continue }
                if exitObservedAt == nil { exitObservedAt = DispatchTime.now().uptimeNanoseconds }
                if (stdoutOpen || stderrOpen) && DispatchTime.now().uptimeNanoseconds - exitObservedAt! < 1_000_000_000 { continue }
                // Child exit is independently observed. Do not wait forever for an
                // inherited pipe held by an out-of-contract descendant.
                let notify = lock.withLock {
                    terminalValue = process.terminationReason == .exit
                        ? .exited(process.terminationStatus) : .signalled(process.terminationStatus)
                    readyValue = nil; return notificationLocked()
                }
                exited.complete(); arrivals.signal(); if let notify { notifications.async(execute: notify) }; return
            }
            if !stdoutOpen { fail(.closed) }
        }
    }
}
