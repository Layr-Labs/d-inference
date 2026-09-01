import Darwin
import Foundation

/// Watches one running command: drains both streams, reaps the process, and
/// enforces the deadline.
///
/// Streams and process must be supervised together. Watching only the streams
/// gets both common cases wrong:
///
/// - A command that closes its own stdout and stderr reaches EOF immediately,
///   so a stream-only loop finishes at once and an unbounded reap then runs for
///   as long as the command likes. A session serves one command at a time, so
///   that wedges the whole agent.
/// - A command that exits quickly but leaves a background child holding the
///   pipe keeps the stream-only loop running to the deadline, reporting a
///   timeout for a command that really finished — and discarding its exit code.
///   `cmd & exit 7` is the commonest shell idiom there is.
enum SandboxGuestCommandSupervisor {
    struct Outcome {
        var standardOutput: BoundedSink
        var standardError: BoundedSink
        var timedOut: Bool
        /// `nil` when the child could not be reaped, which must not be
        /// mistaken for a successful exit 0.
        var status: Int32?
    }

    private static let readChunkBytes = 64 * 1024
    /// How long to keep reading after the command itself exits, so buffered
    /// output is not lost to an orphan still holding the write end.
    private static let streamGraceSeconds: TimeInterval = 0.25
    /// How long to keep draining after a kill before giving up on EOF.
    private static let postKillDrainSeconds: TimeInterval = 5
    private static let pollCapMilliseconds: Double = 50

    static func supervise(
        pid: pid_t,
        outputDescriptor: Int32,
        errorDescriptor: Int32,
        limit: Int,
        deadline: Date
    ) -> Outcome {
        var outputSink = BoundedSink(limit: limit)
        var errorSink = BoundedSink(limit: limit)
        var chunk = [UInt8](repeating: 0, count: readChunkBytes)
        var outputOpen = true
        var errorOpen = true

        var childExited = false
        var reapFailed = false
        var status: Int32 = 0
        var graceDeadline: Date?
        var killDeadline: Date?
        var timedOut = false

        while true {
            if !childExited {
                var reaped: Int32 = 0
                let result = waitpid(pid, &reaped, WNOHANG)
                if result > 0 {
                    childExited = true
                    status = reaped
                    graceDeadline = Date().addingTimeInterval(streamGraceSeconds)
                } else if result < 0 && errno != EINTR {
                    // Already reaped elsewhere, or unwaitable. Do not invent a
                    // status: an uninitialised 0 would decode as a clean exit.
                    childExited = true
                    reapFailed = true
                    graceDeadline = Date().addingTimeInterval(streamGraceSeconds)
                }
            }

            // The command is finished and nothing is still writing.
            if childExited, !outputOpen, !errorOpen { break }
            // The command is finished but an orphan holds a pipe. Take what
            // arrived during the grace window and stop; waiting on an orphan
            // for the rest of the deadline is what produced false timeouts.
            if childExited, let grace = graceDeadline, Date() >= grace { break }

            if !timedOut, Date() >= deadline {
                timedOut = true
                SandboxGuestProcessSpawn.killProcessGroup(pid)
                killDeadline = Date().addingTimeInterval(postKillDrainSeconds)
            }
            if let killDeadline, Date() >= killDeadline { break }

            var descriptors: [pollfd] = []
            if outputOpen {
                descriptors.append(
                    pollfd(fd: outputDescriptor, events: Int16(POLLIN), revents: 0)
                )
            }
            if errorOpen {
                descriptors.append(
                    pollfd(fd: errorDescriptor, events: Int16(POLLIN), revents: 0)
                )
            }

            guard !descriptors.isEmpty else {
                // Both streams closed but the command is still running: sleep
                // briefly so the deadline and the reap keep being checked.
                usleep(useconds_t(pollCapMilliseconds * 1_000))
                continue
            }

            let waitMilliseconds = Int32(
                max(1, min(pollCapMilliseconds, nextWakeMilliseconds(
                    deadline: deadline,
                    graceDeadline: graceDeadline,
                    killDeadline: killDeadline
                )))
            )
            let ready = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
                poll(buffer.baseAddress, nfds_t(buffer.count), waitMilliseconds)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                // A failing poll must not drop us into an unbounded wait; keep
                // looping so the deadline still fires.
                usleep(useconds_t(pollCapMilliseconds * 1_000))
                continue
            }
            if ready == 0 { continue }

            var index = 0
            if outputOpen {
                outputOpen = consume(
                    descriptors[index],
                    descriptor: outputDescriptor,
                    into: &outputSink,
                    chunk: &chunk
                )
                index += 1
            }
            if errorOpen {
                errorOpen = consume(
                    descriptors[index],
                    descriptor: errorDescriptor,
                    into: &errorSink,
                    chunk: &chunk
                )
            }
        }

        if !childExited {
            // Only reachable after a kill, so this terminates.
            if let reaped = SandboxGuestProcessSpawn.wait(for: pid) {
                status = reaped
            } else {
                reapFailed = true
            }
        }

        return Outcome(
            standardOutput: outputSink,
            standardError: errorSink,
            timedOut: timedOut,
            status: reapFailed ? nil : status
        )
    }

    /// Milliseconds until the soonest thing the loop must react to.
    private static func nextWakeMilliseconds(
        deadline: Date,
        graceDeadline: Date?,
        killDeadline: Date?
    ) -> Double {
        let candidates = [deadline, graceDeadline, killDeadline]
            .compactMap { $0?.timeIntervalSinceNow }
            .filter { $0 > 0 }
        guard let soonest = candidates.min() else {
            return pollCapMilliseconds
        }
        return soonest * 1_000
    }

    /// Returns false when the stream reached EOF or failed.
    private static func consume(
        _ entry: pollfd,
        descriptor: Int32,
        into sink: inout BoundedSink,
        chunk: inout [UInt8]
    ) -> Bool {
        guard entry.revents != 0 else { return true }
        let received = chunk.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            while true {
                let result = read(descriptor, base, raw.count)
                if result < 0 && errno == EINTR { continue }
                return result
            }
        }
        if received < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return true }
            return false
        }
        if received == 0 { return false }
        sink.append(chunk.prefix(received))
        return true
    }
}

private extension Optional where Wrapped == Date {
    var timeIntervalSinceNow: TimeInterval? {
        self?.timeIntervalSinceNow
    }
}
