import Darwin
import Foundation

/// Reads and writes whole Ethernet frames on the descriptor the VM's network
/// attachment is connected to.
///
/// One datagram is exactly one frame. That is the attachment's contract, and it
/// is what removes every framing concern a stream socket would bring: no length
/// prefix, no partial frame, no reassembly.
public struct GuestFrameChannel: Sendable {
    public enum ChannelError: Error, Equatable {
        /// The guest is gone. Callers stop, which is what makes the guest's
        /// network die with its VM rather than linger.
        case closed
        case failed(errno: Int32)
    }

    private let descriptor: Int32
    private let maximumFrameBytes: Int

    public init(descriptor: Int32, maximumFrameBytes: Int = 65_535) {
        self.descriptor = descriptor
        self.maximumFrameBytes = maximumFrameBytes
    }

    /// One frame, or nil when nothing is waiting.
    ///
    /// Never blocks: the descriptor is non-blocking, so an empty queue is
    /// `EAGAIN` and reported as nil rather than stalling the caller on a guest
    /// that may never speak.
    public func receive() throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: maximumFrameBytes)
        let count = buffer.withUnsafeMutableBytes { raw in
            Darwin.recv(descriptor, raw.baseAddress, raw.count, 0)
        }
        if count > 0 {
            return Array(buffer[0..<count])
        }
        if count == 0 {
            throw ChannelError.closed
        }
        switch errno {
        case EAGAIN, EINTR:
            return nil
        case ECONNRESET, EPIPE, EBADF:
            throw ChannelError.closed
        default:
            throw ChannelError.failed(errno: errno)
        }
    }

    /// Sends one frame.
    ///
    /// A frame larger than the guest's MTU is refused rather than truncated: a
    /// short write on a datagram socket would deliver a frame the guest would
    /// read as corrupt, which is far harder to diagnose than a refusal.
    public func send(_ frame: [UInt8]) throws {
        guard frame.count <= maximumFrameBytes else {
            throw ChannelError.failed(errno: EMSGSIZE)
        }
        let sent = frame.withUnsafeBytes { raw in
            Darwin.send(descriptor, raw.baseAddress, raw.count, 0)
        }
        if sent == frame.count {
            return
        }
        switch errno {
        case EAGAIN, EINTR:
            // The guest is not draining. Dropping is correct for a link layer;
            // Ethernet is lossy by design and TCP above it will retransmit.
            return
        case ECONNRESET, EPIPE, EBADF, ENOTCONN:
            throw ChannelError.closed
        default:
            throw ChannelError.failed(errno: errno)
        }
    }
}
