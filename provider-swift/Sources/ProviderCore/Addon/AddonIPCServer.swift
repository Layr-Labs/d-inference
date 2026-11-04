import Darwin
import Foundation

/// Serves `hold.v1` on the owner-only add-on socket. A connection is verified
/// when accepted, before it takes one of `maximumConnections` slots, and again
/// for every request. Connections are few and short, so each gets a dedicated
/// thread with bounded, polled blocking I/O; nothing here runs on the Swift
/// cooperative pool except the handler call.
final class AddonIPCServer: @unchecked Sendable {
    typealias Authenticate = @Sendable (audit_token_t) -> AddonPeer?
    typealias Handle = @Sendable (AddonIPC.Request, AddonPeer) async -> AddonIPC.Response

    enum Failure: Error, CustomStringConvertible {
        case pathOccupied(String)
        case inUse(String)
        case system(String, Int32)

        var description: String {
            switch self {
            case .pathOccupied(let path): return "\(path) exists and is not this user's socket"
            case .inUse(let path): return "another process is serving \(path)"
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    static let maximumConnections = 8
    /// An idle connection is closed; the add-on reconnects for its next renew.
    static let idleTimeout: Duration = .seconds(300)
    /// A request line must complete this long after the server first holds
    /// part of it, however slowly the rest trickles in.
    static let requestTimeout: Duration = .seconds(10)
    static let handlerTimeout: Duration = .seconds(30)
    private static let writeTimeout: Duration = .seconds(5)
    private static let pollMilliseconds: Int32 = 200

    let socketURL: URL
    private let authenticate: Authenticate
    private let handle: Handle
    private let requestTimeout: Duration
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var stopped = false
    /// Open connection descriptors. A descriptor leaves this set before it is
    /// closed, so `stop` never shuts down a reused descriptor number.
    private var connections: Set<Int32> = []
    private var boundSocket: (device: dev_t, inode: ino_t)?

    init(socketURL: URL, authenticate: @escaping Authenticate, handle: @escaping Handle,
         requestTimeout: Duration = AddonIPCServer.requestTimeout,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketURL = socketURL
        self.authenticate = authenticate
        self.handle = handle
        self.requestTimeout = requestTimeout
        self.log = log
    }

    // MARK: - Lifecycle

    /// Binds `0600` in the `0700` runtime directory. A stale socket left by a
    /// crashed provider is replaced; a live one is never taken over.
    func start() throws {
        try AddonRuntimeDirectory.prepare(socketURL.deletingLastPathComponent())
        let path = socketURL.path
        try removeStaleSocket(at: path)
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.system("socket", errno) }
        do {
            try Self.configure(listener)
            let bound = try Self.withAddress(path) { Darwin.bind(listener, $0, $1) }
            guard bound == 0 else { throw Failure.system("bind", errno) }
            guard chmod(path, 0o600) == 0 else { throw Failure.system("chmod", errno) }
            var info = stat()
            guard lstat(path, &info) == 0 else { throw Failure.system("lstat", errno) }
            guard Darwin.listen(listener, Int32(Self.maximumConnections)) == 0 else {
                throw Failure.system("listen", errno)
            }
            lock.withLock { boundSocket = (info.st_dev, info.st_ino) }
        } catch {
            Darwin.close(listener)
            throw error
        }
        let thread = Thread { [self] in acceptLoop(listener) }
        thread.name = "darkbloom.addon-ipc.accept"
        thread.start()
    }

    /// Idempotent. Wakes every connection thread, then unlinks the socket only
    /// if it is still the one this server bound. The threads retain the
    /// server until they observe the stop, so the owner must call this.
    func stop() {
        let bound: (device: dev_t, inode: ino_t)? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            for fd in connections { Darwin.shutdown(fd, SHUT_RDWR) }
            let bound = boundSocket
            boundSocket = nil
            return bound
        }
        var info = stat()
        if let bound, lstat(socketURL.path, &info) == 0, info.st_dev == bound.device, info.st_ino == bound.inode {
            unlink(socketURL.path)
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
            throw Failure.pathOccupied(path)
        }
        if Self.acceptsConnections(path) { throw Failure.inUse(path) }
        guard unlink(path) == 0 || errno == ENOENT else { throw Failure.system("unlink", errno) }
    }

    private static func acceptsConnections(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return (try? withAddress(path) { Darwin.connect(fd, $0, $1) }) == 0
    }

    // MARK: - Accept

    private func acceptLoop(_ listener: Int32) {
        defer { Darwin.close(listener) }
        while !isStopped {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Self.pollMilliseconds) > 0 else { continue }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            guard (try? Self.configure(fd)) != nil else { Darwin.close(fd); continue }
            // Verify the signer before the connection takes a slot: a peer
            // that never sends a request must not keep the add-on out.
            guard verifiedPeer(fd) != nil else { Self.refuseUnadmitted(fd, with: .unauthorized); continue }
            let admitted: Bool = lock.withLock {
                guard !stopped, connections.count < Self.maximumConnections else { return false }
                connections.insert(fd)
                return true
            }
            guard admitted else { Self.refuseUnadmitted(fd, with: .unavailable); continue }
            let thread = Thread { [self] in serve(fd) }
            thread.name = "darkbloom.addon-ipc.connection"
            thread.start()
        }
    }

    /// Answers once and closes a connection that never entered `connections`,
    /// so closing it here cannot race `stop`.
    private static func refuseUnadmitted(_ fd: Int32, with code: AddonIPC.ErrorCode) {
        _ = Self.write(AddonIPC.encode(.failure(code)), to: fd)
        Darwin.close(fd)
    }

    // MARK: - Connection

    private func serve(_ fd: Int32) {
        defer {
            lock.withLock { _ = connections.remove(fd) }
            Darwin.close(fd)
        }
        var buffer = Data()
        var lastActivity = ContinuousClock.now
        /// When the server first held the unfinished line now in `buffer`.
        var lineStarted: ContinuousClock.Instant?
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while !isStopped {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                lineStarted = nil
                let (response, keepOpen) = respond(to: line, on: fd)
                guard Self.write(AddonIPC.encode(response), to: fd), keepOpen else { return }
            }
            if !buffer.isEmpty, lineStarted == nil { lineStarted = .now }
            // A line that cannot fit, or does not finish in time however its
            // bytes trickle in, cannot be resynchronized: answer once, close.
            if buffer.count > AddonIPC.maximumMessageBytes
                || lineStarted.map({ ContinuousClock.now - $0 >= requestTimeout }) == true {
                _ = Self.write(AddonIPC.encode(.failure(.invalidRequest)), to: fd)
                return
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollMilliseconds)
            if ready < 0 && errno != EINTR { return }
            if ready <= 0 {
                if ContinuousClock.now - lastActivity >= Self.idleTimeout { return }
                continue
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            lastActivity = .now
        }
    }

    /// The peer is verified again for every request: a peer that later
    /// executed other code no longer matches the audit token captured at connect.
    private func respond(to line: Data, on fd: Int32) -> (AddonIPC.Response, keepOpen: Bool) {
        guard let peer = verifiedPeer(fd) else { return (.failure(.unauthorized), false) }
        switch AddonIPC.parse(line) {
        case .failure(let code):
            return (.failure(code), true)
        case .success(let request):
            return (invoke(request, peer: peer), true)
        }
    }

    /// The connection's kernel audit token checked against the add-on policy.
    private func verifiedPeer(_ fd: Int32) -> AddonPeer? {
        guard let token = AddonPeerPolicy.peerToken(fd), let peer = authenticate(token) else {
            log("Add-on IPC: refused an unauthenticated peer")
            return nil
        }
        return peer
    }

    private func invoke(_ request: AddonIPC.Request, peer: AddonPeer) -> AddonIPC.Response {
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        let handle = self.handle
        Task.detached {
            box.set(await handle(request, peer))
            done.signal()
        }
        let seconds = Double(Self.handlerTimeout.components.seconds)
        guard done.wait(timeout: .now() + seconds) == .success, let response = box.value else {
            return .failure(.unavailable)
        }
        return response
    }

    // MARK: - Descriptors

    private static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.system("fcntl", errno) }
    }

    /// Bounded write of one whole response line.
    private static func write(_ data: Data, to fd: Int32) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: writeTimeout)
        var offset = 0
        while offset < data.count {
            guard ContinuousClock.now < deadline else { return false }
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 { offset += written; continue }
            guard written < 0, errno == EAGAIN || errno == EINTR else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&descriptor, 1, pollMilliseconds)
        }
        return true
    }

    /// Runs `call` (`bind` or `connect`) with `path` as its socket address.
    private static func withAddress<Result>(
        _ path: String, _ call: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) throws -> Result {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.system("bind (path too long)", ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyMemory(from: source) }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                call($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: AddonIPC.Response?
    var value: AddonIPC.Response? { lock.withLock { response } }
    func set(_ value: AddonIPC.Response) { lock.withLock { response = value } }
}
