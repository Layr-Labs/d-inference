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
public final class ClusterWorkerProcess: @unchecked Sendable {
    public let expectedIdentity: ClusterWorkerIdentity
    public let expectedProfile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String
    public let lifetimeDeadline: UInt64
    private let process = Process()
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
    public var launchedProcessIdentifier: Int32? { lock.withLock { launchedPID } }
    public var termination: ClusterWorkerProcessTermination? { lock.withLock { terminalValue } }
    public var observedExit: Bool { exited.isComplete }
    public var readiness: ClusterWorkerReady? { lock.withLock { fault == nil && fenceAt == nil ? readyValue : nil } }
    public var diagnosticTail: Data { lock.withLock { stderrTail } }

    public init(launch: ClusterWorkerLaunch, expectedIdentity: ClusterWorkerIdentity, rank: Int,
                profile: ClusterWorkerProfile, executionPlanSHA256: String, startupDeadline: UInt64, lifetimeDeadline: UInt64) throws {
        _ = try ClusterWorkerSession(identity: expectedIdentity, rank: rank, profile: profile,
            executionPlanSHA256: executionPlanSHA256)
        let now = DispatchTime.now().uptimeNanoseconds
        guard launch.executable.isFileURL, launch.executable.path.hasPrefix("/"),
              launch.arguments.count <= 64, launch.arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              launch.environment.count <= 128,
              launch.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0")
                  && !$0.value.contains("\0") && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8192 }),
              startupDeadline > now, lifetimeDeadline >= startupDeadline,
              lifetimeDeadline - now <= ClusterWorkerLimits.deadlineNanoseconds else {
            throw ClusterWorkerOwnerError.invalid("Invalid worker launch")
        }
        self.expectedIdentity = expectedIdentity; self.rank = rank; expectedProfile = profile
        self.executionPlanSHA256 = executionPlanSHA256; self.startupDeadline = startupDeadline
        self.lifetimeDeadline = lifetimeDeadline
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
            do { try process.run(); launchedPID = process.processIdentifier } catch { fault = .closed; terminalValue = .launchFailed; exited.complete(); wakeup.closeAfterPolling(); throw error }
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

    public func fence() { fail(.closed) }
    public func waitUntilExited() async { await exited.value() }
    func waitForExit() { exited.wait() }

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
                readyValue = ready
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
        var stdoutOpen = true, stderrOpen = true, termSent = false, killSent = false
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
            if let at = lock.withLock({ fenceAt }), process.isRunning {
                if !termSent { process.terminate(); termSent = true }
                if now >= at && now - at >= 2_000_000_000 && !killSent { _ = Darwin.kill(process.processIdentifier, SIGKILL); killSent = true }
            }
            var fds = [pollfd(fd: stdoutOpen ? outFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderrOpen ? errFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: lock.withLock({ outgoing.isEmpty }) ? -1 : inFD, events: Int16(POLLOUT), revents: 0),
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
                process.waitUntilExit()
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
