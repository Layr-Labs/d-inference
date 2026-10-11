import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// The worker's data-plane credential (S16), read once from the first line of
/// its control pipe before the pipe reader starts. Read a byte at a time so
/// nothing after the line is consumed here. Bounded in size and by the
/// worker's first deadline; the secret is never logged.
enum WorkerDataPlaneTrust {
    static func read(descriptor: Int32, until deadline: UInt64, epoch: UUID, rank: Int) throws -> ClusterDataPlaneCredential {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw WorkerFailure.invalid("The data-plane credential did not arrive before the worker's deadline") }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(100, (deadline - now) / 1_000_000 + 1)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, waiting.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw WorkerFailure.invalid("Worker input failed before the data-plane credential")
            }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count == 1 else { throw WorkerFailure.invalid("Worker input ended before the data-plane credential") }
            line.append(byte)
            if byte == 10 { break }
            guard line.count < 4096 else { throw WorkerFailure.invalid("Data-plane credential line exceeds its bound") }
        }
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
