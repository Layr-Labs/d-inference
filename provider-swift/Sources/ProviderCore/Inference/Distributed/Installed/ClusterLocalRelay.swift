import Foundation
import Darwin

/// A pair with its local API on every address (`darkbloom cluster local`, or Both, me first) on each Mac that is not
/// rank 0: its own port answers too, by passing each connection over the cable to the API on the rank 0 Mac. Which Mac
/// is rank 0 follows the plan and can change between starts; without this the API's address changed with it (M4 Max
/// rank 0 on one start, M5 Max on the next, 2026-10-16), and a member had no API at all beside Darkbloom. With `keys`,
/// each request's head is read on its way so this Mac's own key goes on as the pair's (`ClusterLocalRelay+Requests`);
/// every other byte, and every byte of every answer, passes as it comes. The API checks the key. Nothing is kept.
///
/// Rank 0's API sees each relayed request arrive on it from this Mac's cable address. So the request is the owner's
/// use there (with Both, me first, the pair pauses for it as for one made on that Mac), and it comes from another
/// machine (`LocalHTTPClient.isAnotherMachine`), so rank 0's router never takes the paid network for it, whoever on
/// this Mac sent it. Each holds only because the relay dials rank 0's API at its cable address (`rankZeroHost`).
///
/// Each descriptor is closed only by the thread that uses it (`stop` only shuts them down), so a stopped relay never
/// closes a number another socket of this process has taken since. At most `maximumConnections` pass at once, and a
/// connection idle for `idleSeconds` in both directions is ended.
public final class ClusterLocalRelay: @unchecked Sendable {
    public struct Target: Equatable, Sendable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) { self.host = host; self.port = port }
    }

    /// The two keys the relay knows: this Mac's own (`LocalEndpoint.loadOrCreateToken`), which tools on this Mac read,
    /// and the pair's (`LocalEndpoint.loadOrCreateClusterToken`), which the API on rank 0 takes from every relay.
    public struct Keys: Equatable, Sendable {
        public var own: String
        public var pair: String
        public init(own: String, pair: String) { self.own = own; self.pair = pair }
    }

    public static let maximumConnections = 64
    public static let idleSeconds = 600

    public let port: Int
    public let target: Target
    /// Nil: every byte passes as it comes, keys included (the relay the cluster service starts always has keys).
    public let keys: Keys?
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    /// Rank 0's Mac is away, as the cluster service finds it (`setAway`): each client gets the 503 at once.
    private var away = false
    /// The words of the relay's 503s (`setRefusals`).
    private var refusals: Refusals
    private var open: Set<Int32> = []
    private var connections = 0
    /// Signalled when the accept thread has closed the listener (the port is free again).
    private let listenerClosed = DispatchSemaphore(value: 0)

    /// Listens on `bind` (IPv4) at `port` (nil when it cannot: another program holds it) and passes each connection
    /// to `target`, or answers it a 503 in `refusals`' words when it can't.
    public init?(port: Int, bind: String = "0.0.0.0", target: Target, keys: Keys? = nil, refusals: Refusals = .generic) {
        guard (1...65_535).contains(port), (1...65_535).contains(target.port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, bind, &address.sin_addr) == 1 else { close(fd); return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { close(fd); return nil }
        self.port = port; self.target = target; self.keys = keys; self.refusals = refusals; listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { stop() }

    /// Ends the listener and every passed connection (shut down here, closed by the threads that own them), and
    /// returns once the listener is closed (at most 2 s): the port is free for rank 0 when this Mac becomes it.
    public func stop() {
        let descriptors = lock.withLock { () -> [Int32]? in
            guard !stopped else { return nil }
            stopped = true
            return Array(open)
        }
        guard let descriptors else { return }
        for fd in descriptors { shutdown(fd, SHUT_RDWR) }
        _ = listenerClosed.wait(timeout: .now() + 2)
    }

    public var isStopped: Bool { lock.withLock { stopped } }

    /// Whether rank 0's Mac is away: while it is, each client is answered the 503 for an unreachable Mac at once, and
    /// relaying resumes by itself once the cluster service finds that Mac back.
    public func setAway(_ away: Bool) { lock.withLock { self.away = away } }
    public var isAway: Bool { lock.withLock { away } }

    /// The words of the relay's 503s, as the cluster service names the pair's other Mac.
    public func setRefusals(_ refusals: Refusals) { lock.withLock { self.refusals = refusals } }

    /// Registers a descriptor this relay may shut down; false (the caller closes it) once stopped.
    private func track(_ fd: Int32) -> Bool {
        lock.withLock { guard !stopped else { return false }; open.insert(fd); return true }
    }

    private func untrack(_ fd: Int32) { lock.withLock { _ = open.remove(fd) } }

    private func acceptLoop() {
        defer { close(listener); listenerClosed.signal() }
        while !isStopped {
            // A listener is not woken by shutdown on macOS: looked at every 200 ms so `stop` ends it promptly.
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 200)
            if polled < 0, errno != EINTR { lock.withLock { stopped = true }; return }
            guard polled > 0, !isStopped else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED: continue
                // Out of descriptors or memory for now: wait and accept again rather than dying with the port held.
                case EMFILE, ENFILE, ENOBUFS, ENOMEM: usleep(200_000); continue
                default: lock.withLock { stopped = true }; return
                }
            }
            let admitted = lock.withLock { () -> Bool in
                guard !stopped, connections < Self.maximumConnections else { return false }
                connections += 1; open.insert(client); return true
            }
            guard admitted else { close(client); continue }
            Self.configure(client)
            Thread.detachNewThread { [self] in
                pass(client)
                lock.withLock { connections -= 1 }
            }
        }
    }

    /// Passes `client` on to rank 0, or answers it as the local API would when it can't (`refuse`): at once while rank
    /// 0's Mac is away (`setAway`), else when the connection to rank 0 fails (`connectSeconds`). Never a connection that
    /// just closes.
    private func pass(_ client: Int32) {
        defer { untrack(client); close(client) }
        let (away, refusals) = lock.withLock { (self.away, self.refusals) }
        let keys = self.keys
        if away { return Self.refuse(client, .unreachable, refusals: refusals, keys: keys) }
        let upstream: Int32
        switch Self.connect(target, within: Self.connectSeconds) {
        case .connected(let fd): upstream = fd
        case .refused: return Self.refuse(client, .notAnswering, refusals: refusals, keys: keys)
        case .unreachable: return Self.refuse(client, .unreachable, refusals: refusals, keys: keys)
        }
        guard track(upstream) else { close(upstream); return }
        defer { untrack(upstream); close(upstream) }
        let done = DispatchGroup()
        done.enter()
        Thread.detachNewThread {
            if let keys { Self.pumpRequests(from: client, to: upstream, keys: keys) } else { Self.pump(from: client, to: upstream) }
            done.leave()
        }
        done.enter()
        Thread.detachNewThread {
            Self.pump(from: upstream, to: client)
            done.leave()
        }
        done.wait()
    }

    /// No SIGPIPE, no delay for small frames (a stream's tokens), and the idle bound on reads.
    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var idle = timeval(tv_sec: idleSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Copies until either side ends (or stays idle past the bound), then half-closes the other's write side (a
    /// request body's end reaches the API). Shutting down the reading side wakes the other direction's copy.
    static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = readSome(from, into: &buffer)
            guard count > 0 else { break }
            guard writeAll(to, buffer[..<count]) else { shutdown(from, SHUT_RD); return }
        }
        shutdown(to, SHUT_WR)
    }

    /// One read into `buffer`, of at most `limit` bytes, again when a signal cuts it short: the count, 0 at the end,
    /// or -1 (an error, or the idle bound passed).
    static func readSome(_ fd: Int32, into buffer: inout [UInt8], upTo limit: Int = .max) -> Int {
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min(limit, $0.count)) }
            if count < 0, errno == EINTR { continue }
            return count
        }
    }

    /// Writes all of `bytes`; false when `fd` takes no more.
    static func writeAll(_ fd: Int32, _ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// How long the relay waits for rank 0 to take a connection: on the cable one takes well under a millisecond, and a
    /// Mac that is asleep or unplugged never answers (a blocking connect would wait 75 s).
    public static let connectSeconds: Int32 = 3

    /// How a connection to rank 0 went.
    enum Connection {
        case connected(Int32)
        /// Rank 0's Mac answered and refused the port: its API doesn't listen.
        case refused
        /// No answer in time, or no way there: rank 0's Mac can't be reached.
        case unreachable
    }

    static func connect(_ target: Target) -> Int32? {
        guard case .connected(let fd) = connect(target, within: connectSeconds) else { return nil }
        return fd
    }

    /// A connection to `target`, waited for at most `seconds`.
    static func connect(_ target: Target, within seconds: Int32) -> Connection {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable }
        configure(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(target.port).bigEndian)
        guard inet_pton(AF_INET, target.host, &address.sin_addr) == 1 else { close(fd); return .unreachable }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var failure = result == 0 ? 0 : errno
        if failure == EINPROGRESS {
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var polled: Int32
            repeat { polled = poll(&ready, 1, seconds * 1000) } while polled < 0 && errno == EINTR
            if polled > 0 {
                var pending: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                failure = getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length) == 0 ? pending : errno
            } else {
                failure = ETIMEDOUT
            }
        }
        guard failure == 0 else { close(fd); return failure == ECONNREFUSED ? .refused : .unreachable }
        _ = fcntl(fd, F_SETFL, flags)
        return .connected(fd)
    }
}
