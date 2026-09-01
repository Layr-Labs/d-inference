import Darwin
import Foundation
import SandboxGuestProtocol

/// Host end of the guest channel.
///
/// Adopts a descriptor handed over by the run process and speaks
/// `SandboxGuestProtocol` across it. Everything arriving is untrusted: reads
/// are deadline-bounded, the inbound buffer is capped, frame kinds that only
/// ever travel host-to-guest are refused, and a handshake that does not
/// validate is a failure rather than a warning.
///
/// The client owns the descriptor once constructed and closes it on `close()`
/// or deinit.
public final class SandboxGuestChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Equatable, Sendable, CustomStringConvertible {
        case closed
        case timedOut(String)
        case peerClosed(String)
        case readFailed(Int32)
        case writeFailed(Int32)
        case protocolViolation(String)
        case agentFailure(code: String, message: String)

        public var description: String {
            switch self {
            case .closed:
                return "guest channel is closed"
            case .timedOut(let stage):
                return "guest channel timed out during \(stage)"
            case .peerClosed(let stage):
                return "guest closed the channel during \(stage)"
            case .readFailed(let code):
                return "guest channel read failed (errno \(code))"
            case .writeFailed(let code):
                return "guest channel write failed (errno \(code))"
            case .protocolViolation(let reason):
                return "guest channel protocol violation: \(reason)"
            case .agentFailure(let code, let message):
                return "guest agent reported \(code): \(message)"
            }
        }
    }

    private static let readChunkBytes = 64 * 1024
    private static let maximumInboundBuffer =
        SandboxGuestFrameCodec.maximumPayloadBytes
        + SandboxGuestFrameCodec.headerBytes

    private let lock = NSLock()
    private var descriptor: Int32
    private var inbound = Data()

    public init(descriptor: Int32) throws {
        guard descriptor >= 0 else {
            throw ClientError.closed
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else {
            throw ClientError.readFailed(errno)
        }
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    public func close() {
        let value = lock.withLock { () -> Int32 in
            let value = descriptor
            descriptor = -1
            return value
        }
        if value >= 0 {
            Darwin.close(value)
        }
    }

    // MARK: - Protocol operations

    /// Reads and validates the agent's opening handshake.
    public func handshake(
        expectedImageID: String? = nil,
        timeout: TimeInterval
    ) throws -> SandboxGuestHandshake {
        let frame = try readFrame(deadline: Date().addingTimeInterval(timeout), stage: "handshake")
        guard frame.kind == .handshake else {
            throw ClientError.protocolViolation(
                "expected a handshake, received \(frame.kind)"
            )
        }
        guard let handshake = try? JSONDecoder().decode(
            SandboxGuestHandshake.self,
            from: frame.payload
        ) else {
            throw ClientError.protocolViolation("handshake payload is not decodable")
        }
        guard handshake.isAcceptable(expectedImageID: expectedImageID) else {
            throw ClientError.protocolViolation(
                "handshake rejected: agent \(handshake.agentVersion), "
                    + "protocol \(handshake.protocolVersion), image \(handshake.imageID)"
            )
        }
        return handshake
    }

    /// Sends a command and returns the raw result envelope bytes.
    ///
    /// The bytes are returned unparsed on purpose: the caller persists them in
    /// the journal and decodes them with the existing host decoder, so this
    /// client never becomes a second source of truth for the envelope format.
    public func execute(
        _ command: SandboxGuestCommandWire,
        timeout: TimeInterval
    ) throws -> Data {
        let payload = try JSONEncoder().encode(command)
        try write(SandboxGuestFrame(kind: .commandRequest, payload: payload))

        let frame = try readFrame(
            deadline: Date().addingTimeInterval(timeout),
            stage: "command result"
        )
        switch frame.kind {
        case .commandResult:
            return frame.payload
        case .failure:
            let failure = try? JSONDecoder().decode(
                SandboxGuestFailure.self,
                from: frame.payload
            )
            throw ClientError.agentFailure(
                code: failure?.code ?? "unknown",
                message: failure?.message ?? "agent reported an undecodable failure"
            )
        case .handshake, .commandRequest:
            throw ClientError.protocolViolation(
                "expected a result, received \(frame.kind)"
            )
        }
    }

    // MARK: - Framing

    private func write(_ frame: SandboxGuestFrame) throws {
        let encoded = try SandboxGuestFrameCodec.encode(frame)
        var offset = 0
        while offset < encoded.count {
            let written: Int = try lock.withLock { () throws -> Int in
                guard descriptor >= 0 else { throw ClientError.closed }
                return encoded.withUnsafeBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return -1 }
                    return Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                }
            }
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitReadable(writable: true, deadline: Date().addingTimeInterval(5), stage: "write")
                    continue
                }
                throw ClientError.writeFailed(errno)
            }
            if written == 0 {
                throw ClientError.peerClosed("write")
            }
            offset += written
        }
    }

    private func readFrame(deadline: Date, stage: String) throws -> SandboxGuestFrame {
        while true {
            if let frame = try decodeBuffered() {
                return frame
            }
            try waitReadable(writable: false, deadline: deadline, stage: stage)
            try fill(stage: stage)
        }
    }

    private func decodeBuffered() throws -> SandboxGuestFrame? {
        try lock.withLock { () throws -> SandboxGuestFrame? in
            do {
                return try SandboxGuestFrameCodec.decode(from: &inbound)
            } catch {
                throw ClientError.protocolViolation("\(error)")
            }
        }
    }

    private func fill(stage: String) throws {
        var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)
        let received: Int = try lock.withLock { () throws -> Int in
            guard descriptor >= 0 else { throw ClientError.closed }
            let socket = descriptor
            return chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                while true {
                    let result = Darwin.read(socket, base, raw.count)
                    if result < 0 && errno == EINTR { continue }
                    return result
                }
            }
        }
        if received < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            throw ClientError.readFailed(errno)
        }
        if received == 0 {
            throw ClientError.peerClosed(stage)
        }
        try lock.withLock { () throws -> Void in
            inbound.append(contentsOf: chunk.prefix(received))
            // The codec caps a declared frame, but a peer that never completes
            // one must not be able to grow this without bound.
            guard inbound.count <= Self.maximumInboundBuffer else {
                throw ClientError.protocolViolation(
                    "inbound buffer exceeded the frame limit"
                )
            }
        }
    }

    private func waitReadable(
        writable: Bool,
        deadline: Date,
        stage: String
    ) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ClientError.timedOut(stage)
            }
            let socket = lock.withLock { descriptor }
            guard socket >= 0 else { throw ClientError.closed }

            var descriptors = pollfd(
                fd: socket,
                events: Int16(writable ? POLLOUT : POLLIN),
                revents: 0
            )
            let milliseconds = Int32(min(remaining * 1_000, 60_000).rounded(.up))
            let ready = poll(&descriptors, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ClientError.readFailed(errno)
            }
            if ready == 0 {
                continue
            }
            if descriptors.revents & Int16(POLLHUP) != 0,
               descriptors.revents & Int16(writable ? POLLOUT : POLLIN) == 0 {
                throw ClientError.peerClosed(stage)
            }
            return
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
