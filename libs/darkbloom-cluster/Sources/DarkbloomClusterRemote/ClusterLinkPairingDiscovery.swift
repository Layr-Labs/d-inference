import Darwin
import Foundation

/// Finds the Mac listening for a pairing on the other end of the cable, so
/// nobody types an address (PROD-PLAN S17, owner gate: no SSH and no network
/// settings in the user path; macOS's own self-assigned addresses suffice).
///
/// A Mac that wants to dial broadcasts a small `probe` datagram on the link
/// interface (bound with IP_BOUND_IF, so it never leaves through Wi-Fi). A
/// listening Mac answers it with `here`: its pairing port and its address on
/// the link. Nothing here is secret or trusted: a forged `here` can only make
/// a Mac dial something that then cannot show the same six digits as the
/// other screen, which the ceremony already refuses. The responder answers at
/// most `maximumRepliesPerSecond` probes a second and never more than one
/// datagram per probe, so it cannot be used to amplify traffic.
public enum ClusterLinkPairingDiscovery {
    static let magic: [UInt8] = Array("DBPAIR1".utf8)
    static let datagramLength = 7 + 1 + 16 + 2 + 4
    static let maximumRepliesPerSecond = 20

    enum Kind: UInt8 { case probe = 1, here = 2 }

    /// A listener that answered.
    public struct Found: Sendable, Hashable {
        public let address: ClusterLinkIPv4Address
        public let port: UInt16
        public init(address: ClusterLinkIPv4Address, port: UInt16) { self.address = address; self.port = port }
    }

    struct Datagram: Equatable {
        var kind: Kind
        var nonce: [UInt8]
        var port: UInt16
        var address: ClusterLinkIPv4Address

        func encoded() -> [UInt8] {
            var bytes = magic
            bytes.append(kind.rawValue)
            bytes += nonce
            bytes += [UInt8(port >> 8), UInt8(port & 0xFF)]
            let v = address.value
            bytes += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            return bytes
        }

        /// Exactly what `encoded()` writes; anything else is nil.
        static func decode(_ bytes: [UInt8]) -> Datagram? {
            guard bytes.count == datagramLength, Array(bytes[0..<7]) == magic, let kind = Kind(rawValue: bytes[7]) else { return nil }
            let nonce = Array(bytes[8..<24])
            let port = UInt16(bytes[24]) << 8 | UInt16(bytes[25])
            let value = UInt32(bytes[26]) << 24 | UInt32(bytes[27]) << 16 | UInt32(bytes[28]) << 8 | UInt32(bytes[29])
            if kind == .here, port == 0 || value == 0 { return nil }
            return Datagram(kind: kind, nonce: nonce, port: port, address: ClusterLinkIPv4Address(value: value))
        }
    }

    static func nonce() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        return bytes
    }

    /// Where a probe goes on this interface: the subnet's directed broadcast
    /// (169.254.255.255 on a self-assigned bridge), or the loopback address
    /// under the test policy.
    static func probeTarget(for local: ClusterLinkInterfaceAddress) -> ClusterLinkIPv4Address {
        if local.address.isLoopback { return .loopback }
        if local.netmask == 0xFFFF_FFFF { return ClusterLinkIPv4Address(value: 0xFFFF_FFFF) }
        return ClusterLinkIPv4Address(value: local.address.value | ~local.netmask)
    }

    /// Whether a `here` names a listener this Mac may dial: on the link's
    /// subnet and not this Mac itself (loopback: only the loopback address).
    static func admissible(_ found: ClusterLinkIPv4Address, local: ClusterLinkInterfaceAddress) -> Bool {
        if local.address.isLoopback { return found.isLoopback }
        return local.contains(found) && found != local.address && found.value != (local.address.value | ~local.netmask)
    }

    /// Which of two listeners that heard each other dials: the one with the
    /// lower address; the other keeps listening. Deterministic on both Macs.
    public static func shouldYield(local: ClusterLinkIPv4Address, other: ClusterLinkIPv4Address) -> Bool {
        other.value < local.value
    }

    // MARK: Sockets

    static func udpSocket(interfaceIndex: UInt32, bind address: ClusterLinkIPv4Address, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw LinkSocketError.system(errno) }
        do {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            if interfaceIndex != 0 { try LinkSocket.setOption(fd, IPPROTO_IP, IP_BOUND_IF, Int32(bitPattern: interfaceIndex)) }
            try LinkSocket.setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            try LinkSocket.setOption(fd, SOL_SOCKET, SO_REUSEPORT, 1)
            try LinkSocket.setOption(fd, SOL_SOCKET, SO_BROADCAST, 1)
            var local = address.socketAddress(port: port)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { throw LinkSocketError.system(errno) }
            try LinkSocket.setNonblocking(fd)
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    static func send(_ fd: Int32, _ datagram: Datagram, to address: ClusterLinkIPv4Address, port: UInt16) {
        let bytes = datagram.encoded()
        var target = address.socketAddress(port: port)
        _ = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// One datagram waiting on `fd`, with its source, or nil.
    static func receive(_ fd: Int32) -> (Datagram, ClusterLinkIPv4Address, UInt16)? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var source = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length) }
            }
        }
        guard count > 0, source.sin_family == sa_family_t(AF_INET),
              let datagram = Datagram.decode(Array(buffer[0..<count])) else { return nil }
        return (datagram, ClusterLinkIPv4Address(value: UInt32(bigEndian: source.sin_addr.s_addr)), UInt16(bigEndian: source.sin_port))
    }

    static func waitReadable(_ fd: Int32, milliseconds: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, max(0, milliseconds)) > 0 && entry.revents & Int16(POLLIN) != 0
    }

    // MARK: Finding a listener

    /// Probes the link for `seconds` (resending every 0.4 s) and returns the
    /// listeners that answered, at most a short settle time after the first
    /// answer. An empty list when nothing answered or the socket could not
    /// be opened.
    public static func find(selection: ClusterLinkInterfaceSelection, port: UInt16 = ClusterLinkPairing.defaultPort,
                            seconds: Double) -> [Found] {
        let fd: Int32
        do { fd = try udpSocket(interfaceIndex: selection.index, bind: selection.local.address, port: 0) } catch { return [] }
        defer { Darwin.close(fd) }
        let probe = Datagram(kind: .probe, nonce: nonce(), port: 0, address: selection.local.address)
        let target = probeTarget(for: selection.local)
        let start = linkNow()
        let end = start &+ UInt64(max(0, seconds) * 1e9)
        var settleEnd: UInt64?
        var nextProbe = start
        var found = [Found]()
        while true {
            let now = linkNow()
            let stop = settleEnd.map { min($0, end) } ?? end
            if now >= stop { break }
            if now >= nextProbe {
                send(fd, probe, to: target, port: port)
                nextProbe = now &+ 400_000_000
            }
            let wait = Int32((min(stop, nextProbe) - min(now, min(stop, nextProbe))) / 1_000_000) + 1
            guard waitReadable(fd, milliseconds: wait) else { continue }
            while let item = receive(fd) {
                let datagram = item.0
                guard datagram.kind == .here, datagram.nonce == probe.nonce,
                      admissible(datagram.address, local: selection.local) else { continue }
                let listener = Found(address: datagram.address, port: datagram.port)
                if !found.contains(listener) { found.append(listener) }
                if settleEnd == nil { settleEnd = linkNow() &+ 300_000_000 }
            }
        }
        return found
    }

    // MARK: Answering probes

    /// Answers probes on the listener's interface while it listens. With
    /// `announce`, it also probes itself every 1.5 s and reports any other
    /// listener that answers (two Macs both started listening).
    public final class Responder: @unchecked Sendable {
        let selection: ClusterLinkInterfaceSelection
        let udpPort: UInt16
        let tcpPort: UInt16
        let announce: Bool
        let heard: @Sendable (Found) -> Void
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var stopped = false
        private var thread: Thread?
        private let done = DispatchSemaphore(value: 0)
        private let ownNonce = ClusterLinkPairingDiscovery.nonce()

        public init(selection: ClusterLinkInterfaceSelection, udpPort: UInt16 = ClusterLinkPairing.defaultPort, tcpPort: UInt16,
                    announce: Bool = false, heard: @escaping @Sendable (Found) -> Void = { _ in }) {
            self.selection = selection; self.udpPort = udpPort; self.tcpPort = tcpPort; self.announce = announce; self.heard = heard
        }

        public func start() throws {
            // Bound to any address on the one interface: a socket bound to a
            // unicast address does not receive the subnet broadcast.
            let socket = try udpSocket(interfaceIndex: selection.index, bind: ClusterLinkIPv4Address(value: 0), port: udpPort)
            lock.withLock { fd = socket }
            let thread = Thread { [self] in loop(socket); done.signal() }
            thread.name = "darkbloom.cluster-pairing.discovery"
            self.thread = thread
            thread.start()
        }

        public func stop() {
            let started: Bool = lock.withLock {
                let was = !stopped && fd >= 0
                stopped = true
                return was
            }
            guard started else { return }
            done.wait()
            lock.withLock { if fd >= 0 { Darwin.close(fd); fd = -1 } }
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        private func loop(_ socket: Int32) {
            let here = Datagram(kind: .here, nonce: [], port: tcpPort, address: selection.local.address)
            let ownProbe = Datagram(kind: .probe, nonce: ownNonce, port: 0, address: selection.local.address)
            let target = probeTarget(for: selection.local)
            var windowStart = linkNow()
            var replies = 0
            var nextProbe = linkNow()
            var reported = Set<Found>()
            while !isStopped {
                if announce, linkNow() >= nextProbe {
                    send(socket, ownProbe, to: target, port: udpPort)
                    nextProbe = linkNow() &+ 1_500_000_000
                }
                guard waitReadable(socket, milliseconds: 200) else { continue }
                while let item = receive(socket) {
                    let (datagram, source, sourcePort) = item
                    switch datagram.kind {
                    case .probe:
                        guard datagram.nonce != ownNonce else { continue }
                        let now = linkNow()
                        if now &- windowStart >= 1_000_000_000 { windowStart = now; replies = 0 }
                        guard replies < maximumRepliesPerSecond else { continue }
                        // Only a prober on this link: a reply never leaves for another subnet.
                        guard selection.local.address.isLoopback ? source.isLoopback : selection.local.contains(source) else { continue }
                        replies += 1
                        var reply = here
                        reply.nonce = datagram.nonce
                        ClusterLinkPairingDiscovery.send(socket, reply, to: source, port: sourcePort)
                    case .here:
                        guard announce, datagram.nonce == ownNonce, datagram.address != selection.local.address,
                              admissible(datagram.address, local: selection.local) else { continue }
                        let listener = Found(address: datagram.address, port: datagram.port)
                        if reported.insert(listener).inserted { heard(listener) }
                    }
                }
            }
        }
    }
}
