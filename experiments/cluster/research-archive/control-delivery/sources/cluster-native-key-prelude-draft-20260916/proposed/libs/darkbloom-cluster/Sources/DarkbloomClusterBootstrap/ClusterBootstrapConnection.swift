import Darwin
import Foundation

/// One in-flight native bootstrap round on a dedicated same-Mac channel.
/// Errors poison this connection. cancel/EOF is not native retirement proof.
public final class ClusterBootstrapConnection: @unchecked Sendable {
    public let identity: ClusterBootstrapIdentity
    public let deadlineUptimeNanoseconds: UInt64
    private let socket: BootstrapSocket
    private let worker: Bool
    private let authorization: BootstrapAuthorization
    private let lock = NSLock()
    private var busy = false, failed = false
    private var sequence: UInt64 = 0
    private var pending: ClusterBootstrapRound?

    init(socket: BootstrapSocket, identity: ClusterBootstrapIdentity, worker: Bool,
         mode: ClusterBootstrapMode = .mesh2) {
        self.socket = socket; self.identity = identity; self.worker = worker
        authorization = .init(worker: worker, mode: mode)
        deadlineUptimeNanoseconds = socket.deadline
    }

    public static func connect(path: String, ownerProcessID: Int32, identity: ClusterBootstrapIdentity,
                               deadlineUptimeNanoseconds: UInt64,
                               mode: ClusterBootstrapMode = .mesh2) throws -> ClusterBootstrapConnection {
        guard ownerProcessID == getppid(), ownerProcessID > 1 else { throw ClusterBootstrapError.peer }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var directoryMetadata = stat()
        guard lstat(directory, &directoryMetadata) == 0, directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(), directoryMetadata.st_mode & 0o777 == 0o700 else {
            throw ClusterBootstrapError.invalid("Bootstrap directory is not private")
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600 else {
            throw ClusterBootstrapError.invalid("Bootstrap path is not the owned private socket")
        }
        var address = try bootstrapAddress(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClusterBootstrapError.system(errno) }
        let socket = try BootstrapSocket(taking: fd, deadline: deadlineUptimeNanoseconds)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw ClusterBootstrapError.system(errno) }
            try socket.wait(Int16(POLLOUT))
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw ClusterBootstrapError.closed
            }
        }
        try socket.requirePeer(processID: ownerProcessID)
        return .init(socket: socket, identity: identity, worker: true, mode: mode)
    }

    public func cancel() { lock.withLock { failed = true }; socket.cancel() }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        do {
            try lock.withLock {
                guard !failed, !busy else { throw ClusterBootstrapError.closed }; busy = true
            }
            let value = try body(); try socket.check()
            try lock.withLock {
                guard !failed else { throw ClusterBootstrapError.closed }; busy = false
            }
            return value
        } catch { cancel(); throw error }
    }

    public func exchange(sequence: UInt64, contribution: Data) throws -> Data {
        try operation {
            try authorization.requireMesh()
            guard worker, sequence == self.sequence else { throw ClusterBootstrapError.invalid("Unexpected worker round") }
            let round = try ClusterBootstrapRound(identity: identity, sequence: sequence, contribution: contribution)
            try socket.write(BootstrapHeader(round: round, reply: false).encoded()); try socket.write(contribution)
            let header = try BootstrapHeader(socket.readExactly(BootstrapHeader.byteCount))
            guard header.reply, header.identity == identity, header.sequence == sequence,
                  header.contributionBytes == contribution.count else { throw ClusterBootstrapError.invalid("Reply identity differs") }
            let result = try socket.readExactly(header.payloadBytes)
            try requireEcho(result, round: round); self.sequence += 1
            return result
        }
    }

    public func receiveRound() throws -> ClusterBootstrapRound {
        try operation {
            try authorization.requireMesh()
            guard !worker, pending == nil else { throw ClusterBootstrapError.invalid("Unexpected owner read") }
            let header = try BootstrapHeader(socket.readExactly(BootstrapHeader.byteCount))
            guard !header.reply, header.identity == identity, header.sequence == sequence else {
                throw ClusterBootstrapError.invalid("Round identity differs")
            }
            let round = try ClusterBootstrapRound(identity: identity, sequence: sequence,
                contribution: socket.readExactly(header.payloadBytes))
            pending = round; return round
        }
    }

    public func reply(to round: ClusterBootstrapRound, gathered: Data) throws {
        try operation {
            try authorization.requireMesh()
            guard !worker, pending == round else { throw ClusterBootstrapError.invalid("Unexpected owner reply") }
            try requireEcho(gathered, round: round)
            try socket.write(BootstrapHeader(round: round, reply: true).encoded()); try socket.write(gathered)
            pending = nil; sequence += 1
        }
    }

    /// Only the actual native-side PID-authenticated connection can mint this
    /// context. Public start bytes alone cannot initialize a native key holder.
    public func beginNativeKeyPrelude(expecting start: Data) throws -> ClusterNativePreludeContext {
        try operation {
            guard worker else { throw ClusterBootstrapError.peer }
            try authorization.nativeStart(start, socket: socket, identity: identity)
            return .init(connection: self, start: start)
        }
    }

    /// The caller must already own a current coordinator start grant and actual
    /// child. This local transport does not approve native code or membership.
    public func beginOwnerKeyPrelude(start: Data) throws -> ClusterOwnerPreludeContext {
        try operation {
            guard !worker else { throw ClusterBootstrapError.peer }
            try authorization.ownerStart(start, socket: socket, identity: identity)
            return .init(connection: self)
        }
    }

    func nativeKeyExchange(_ bytes: Data, confirmation: Bool) throws -> Data {
        try operation { try authorization.nativeExchange(bytes, confirmation: confirmation,
            socket: socket, identity: identity) }
    }
    func nativeKeyComplete(_ digest: Data) throws {
        try operation { try authorization.nativeComplete(digest, socket: socket, identity: identity) }
    }
    func ownerKeyRead(confirmation: Bool) throws -> Data {
        try operation { try authorization.ownerRead(confirmation: confirmation, socket: socket, identity: identity) }
    }
    func ownerKeyWrite(_ bytes: Data, confirmation: Bool) throws {
        try operation { try authorization.ownerWrite(bytes, confirmation: confirmation, socket: socket, identity: identity) }
    }
    func ownerKeyComplete(_ digest: Data) throws {
        try operation { try authorization.ownerComplete(digest, socket: socket, identity: identity) }
    }
    func checkKeyPrelude() throws {
        guard !lock.withLock({ failed }) else { throw ClusterBootstrapError.closed }
        try socket.check()
    }

    private func requireEcho(_ bytes: Data, round: ClusterBootstrapRound) throws {
        let count = round.contribution.count, start = identity.rank * round.contribution.count
        guard bytes.count == count * 2 else { throw ClusterBootstrapError.invalid("Gathered result size differs") }
        let lower = bytes.index(bytes.startIndex, offsetBy: start), upper = bytes.index(lower, offsetBy: count)
        guard Data(bytes[lower..<upper]) == round.contribution else {
            throw ClusterBootstrapError.invalid("Gathered result size or local bytes differ")
        }
    }
}
