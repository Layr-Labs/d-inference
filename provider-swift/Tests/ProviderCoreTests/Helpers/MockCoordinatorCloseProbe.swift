/// Close-frame observation for `MockCoordinator`'s provider WebSocket.
///
/// Hummingbird consumes the peer's close frame inside `WebSocketInboundStream`
/// (the route handler only sees its iterator end) and discards the close code
/// the WSCore handler returns, so a route handler cannot tell a clean close
/// (a close frame, which the real coordinator records as `ws_close_1001`)
/// from a transport drop (which it records as `read_error` and answers by
/// flushing every in-flight request as a 502). The shutdown-ordering tests
/// need exactly that distinction, so the mock's route keeps the NIO channel
/// and installs a pass-through frame probe right after the frame decoder.

import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOWebSocket

/// Request context for the mock's WebSocket route that retains the NIO
/// channel so the route can install `WebSocketCloseFrameProbe` on it.
struct MockWebSocketRequestContext: RequestContext, WebSocketRequestContext {
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<Self>
    let channel: any Channel

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.webSocket = .init()
        self.channel = source.channel
    }
}

/// Pass-through inbound handler that reports the status code of every close
/// frame the peer sends. The "no status" sentinel (1005) stands in for a
/// close frame without a payload, mirroring the WebSocket convention.
final class WebSocketCloseFrameProbe: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = WebSocketFrame

    static let noStatusCode: UInt16 = 1005

    private let onClose: @Sendable (UInt16) -> Void

    init(onClose: @escaping @Sendable (UInt16) -> Void) {
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.opcode == .connectionClose {
            var payload = frame.unmaskedData
            onClose(payload.readInteger(as: UInt16.self) ?? Self.noStatusCode)
        }
        context.fireChannelRead(data)
    }

    /// Install the probe after the WebSocket frame decoder so it sees decoded
    /// frames and hands every one of them on unchanged.
    static func install(
        on channel: any Channel,
        onClose: @escaping @Sendable (UInt16) -> Void
    ) async throws {
        // Pipeline surgery on the channel's own event loop (the handlers are
        // not Sendable, so they never cross it).
        try await channel.eventLoop.submit {
            let operations = channel.pipeline.syncOperations
            let decoder = try operations.handler(
                type: ByteToMessageHandler<WebSocketFrameDecoder>.self)
            try operations.addHandler(
                WebSocketCloseFrameProbe(onClose: onClose), position: .after(decoder))
        }.get()
    }
}
