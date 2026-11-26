// Coordinator WebSocket reads, kept apart from the handling of what they read.

import Foundation
import Network

/// Reads one coordinator connection's WebSocket messages on the connection's
/// own queue and hands each application message to `frames` in order.
///
/// The next read is armed inside the callback of the one before, never after
/// the message has been handled. Handling a message waits on the
/// `CoordinatorClient` actor (decoding, validation, a large request body). When
/// it took longer than the link's dead bound, the socket was not read meanwhile:
/// pongs and the next frames stayed unread, the link watch saw silence and
/// dropped a live link, and the coordinator's writes to this provider stalled
/// against its write deadline. Reading on here keeps every frame, and with it
/// every pong, counting as liveness while a message is being handled.
///
/// A close frame, a transport error or a frame without data or a control opcode
/// ends the stream with `CoordinatorError.connectionClosed`, after every
/// message read before it; the close frame's code is recorded on `session`
/// first, as before. Cancelling the consumer cancels the connection, so a read
/// still pending on it returns at once.
///
/// Every message read is added to `backlog` before it is handed over. Once the
/// backlog passes a size limit (`CoordinatorInboundBacklog`) the reader stops
/// reading, and the ping task ends the link with close code 4003; no message
/// is dropped.
final class CoordinatorFrameReader: @unchecked Sendable {
    /// One application message and when its read completed.
    struct Frame: Sendable {
        let data: Data
        /// Stamped in the read callback, before any queueing, so a first-content
        /// budget counts the time a message waits to be handled.
        let receivedAt: ContinuousClock.Instant
        /// The profiler's anchor on the suspending clock, taken beside `receivedAt`.
        let profileAnchor: SuspendingClock.Instant
    }

    private let connection: NWConnection
    private let session: CoordinatorSessionRecorder
    private let activity: LinkActivityTracker
    private let backlog: CoordinatorFrameBacklog
    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation

    private init(connection: NWConnection, session: CoordinatorSessionRecorder, activity: LinkActivityTracker,
                 backlog: CoordinatorFrameBacklog, continuation: AsyncThrowingStream<Frame, Error>.Continuation) {
        self.connection = connection
        self.session = session
        self.activity = activity
        self.backlog = backlog
        self.continuation = continuation
    }

    /// Starts reading `connection` and returns its application messages.
    static func frames(on connection: NWConnection, session: CoordinatorSessionRecorder,
                       activity: LinkActivityTracker,
                       backlog: CoordinatorFrameBacklog) -> AsyncThrowingStream<Frame, Error> {
        let (frames, continuation) = AsyncThrowingStream<Frame, Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination { connection.cancel() }
        }
        CoordinatorFrameReader(connection: connection, session: session, activity: activity,
                               backlog: backlog, continuation: continuation).read()
        return frames
    }

    private func read() {
        // NWProtocolWebSocket delivers one complete WebSocket message per call.
        // The callback holds this reader until the next read is armed or the
        // stream has ended.
        connection.receiveMessage { [self] data, context, _, error in
            // Stamp at the transport callback, before any queueing or decoding
            // can consume the coordinator's relative deadline.
            let receivedAt = ContinuousClock.now
            let profileAnchor = SuspendingClock.now
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            // Record a close frame's code here, also when the read ends with an
            // error: the transport state change that follows the frame can end
            // the session before the stream is read.
            if let metadata, metadata.opcode == .close, let code = metadata.sentCloseCode(content: data) {
                session.recordCloseCode(code)
            }
            if let error {
                continuation.finish(throwing: CoordinatorError.connectionClosed(error))
                return
            }
            // Any frame proves the link is alive, so a busy stream never waits on a pong.
            activity.recordInbound()
            // A close frame's content is the close payload, not a JSON message.
            if metadata?.opcode == .close {
                continuation.finish(throwing: CoordinatorError.connectionClosed(NWError.posix(.ECONNRESET)))
                return
            }
            switch CoordinatorClient.inboundFrame(data: data, opcode: metadata?.opcode) {
            case .control:
                break
            case .transportClosed:
                continuation.finish(throwing: CoordinatorError.connectionClosed(NWError.posix(.ECONNRESET)))
                return
            case .message(let message):
                let withinLimits = backlog.add(size: message.count, receivedAt: receivedAt)
                continuation.yield(Frame(data: message, receivedAt: receivedAt, profileAnchor: profileAnchor))
                // Past a size limit: read no more; the ping task ends the link.
                guard withinLimits else { return }
            }
            read()
        }
    }
}
