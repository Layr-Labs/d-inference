import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// One secret line the owner writes at the head of the worker's control pipe
/// before the pipe reader starts. Read a byte at a time so nothing after the
/// line is consumed here. Bounded in size and by the worker's first deadline;
/// the line is never logged, and no error names its contents.
enum WorkerInitialInputLine {
    static func read(descriptor: Int32, until deadline: UInt64, what: String) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw WorkerFailure.invalid("The \(what) did not arrive before the worker's deadline") }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(100, (deadline - now) / 1_000_000 + 1)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, waiting.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw WorkerFailure.invalid("Worker input failed before the \(what)")
            }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count == 1 else { throw WorkerFailure.invalid("Worker input ended before the \(what)") }
            line.append(byte)
            if byte == 10 { break }
            guard line.count < 4096 else { throw WorkerFailure.invalid("The \(what) line exceeds its bound") }
        }
        return line
    }
}

/// The worker's data-plane credential (S16), read once from the first line of
/// its control pipe before the pipe reader starts.
enum WorkerDataPlaneTrust {
    static func read(descriptor: Int32, until deadline: UInt64, epoch: UUID, rank: Int) throws -> ClusterDataPlaneCredential {
        let line = try WorkerInitialInputLine.read(descriptor: descriptor, until: deadline, what: "data-plane credential")
        let trust = try ClusterWorkerCodec.decodeDataPlaneTrust(line)
        guard trust.membershipEpoch == epoch, trust.rank == rank else {
            throw WorkerFailure.invalid("Data-plane credential belongs to another epoch or rank")
        }
        do {
            return try ClusterDataPlaneCredential(epoch: epoch, rank: rank, workerSigningKey: trust.workerSigningKey,
                workerCertificate: trust.workerCertificate, memberIdentity: trust.memberIdentity, peerPin: trust.peerPin)
        } catch {
            throw WorkerFailure.invalid("Data-plane credential refused: \(error)")
        }
    }
}

/// The key of this rank's prompt-prefix SSD tier (`--prefix-ssd-key`), read
/// once from the control pipe right after the data-plane credential (first
/// when there is none). It is bound to this worker's epoch and rank and is
/// handed to the load in-process; the environment never carries it.
enum WorkerPrefixSSDKey {
    static func read(descriptor: Int32, until deadline: UInt64, epoch: UUID, rank: Int) throws -> Data {
        let line = try WorkerInitialInputLine.read(descriptor: descriptor, until: deadline, what: "prefix-SSD key")
        let value: ClusterWorkerPrefixSSDKey
        do { value = try ClusterWorkerCodec.decodePrefixSSDKey(line) } catch {
            // The codec's own reason (shape, length, unknown field); never the bytes.
            throw WorkerFailure.invalid("Prefix-SSD key line refused: \(error)")
        }
        guard value.membershipEpoch == epoch, value.rank == rank else {
            throw WorkerFailure.invalid("The prefix-SSD key belongs to another epoch or rank")
        }
        return value.key
    }

    /// Before anything else: a key, or a key file, in the environment means a
    /// launcher from before this delivery. Refused by name (never by value),
    /// so the mismatch is loud and the worker never runs with the key there.
    static func refuseEnvironmentKey(_ environment: [String: String]) throws {
        for name in ClusterWorkerPrefixSSDKey.retiredEnvironmentNames where environment[name] != nil {
            throw WorkerFailure.invalid("\(name) is never read from the environment: the key comes only on the worker input "
                + "(--prefix-ssd-key \(ClusterWorkerPrefixSSDKey.argument)); install an owner built with it")
        }
    }
}
