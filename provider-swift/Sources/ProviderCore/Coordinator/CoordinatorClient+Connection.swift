// CoordinatorClient connection lifecycle: reconnect loop with backoff, a single
// WebSocket session (ping/heartbeat/reachability), the receive loop, and reconnect telemetry.

import Foundation
import Network

#if canImport(os)
import os
#endif

extension CoordinatorClient {
    // MARK: - Connection Loop

    internal func runLoop() async {
        var reconnectCount: UInt64 = 0

        while !shutdownRequested {
            logger.info("Connecting to coordinator: \(self.config.url)")

            do {
                try await connectAndRun()
                logger.info("Coordinator connection closed, reconnecting...")
                markRegistrationSucceeded()
                continue
            } catch {
                if shutdownRequested { break }

                eventContinuation?.yield(.disconnected)
                let delay = nextReconnectDelay()
                let reachable = reachability.isReachable
                logger.warning(
                    "Coordinator connection error: \(error.localizedDescription). network_reachable=\(reachable). Reconnecting in \(delay)s"
                )

                reconnectCount += 1
                if shouldEmitReconnectTelemetry(count: reconnectCount) {
                    emitReconnectTelemetry(count: reconnectCount, error: error)
                }

                do {
                    try await taskSleep( .seconds(delay))
                } catch {
                    // Task cancelled = shutdown
                    break
                }
            }
        }

        logger.info("Coordinator client shut down")
        eventContinuation?.finish()
        runLoopTask = nil
    }

    // MARK: - Single Connection Session

    private func connectAndRun() async throws {
        guard let url = URL(string: config.url) else {
            throw CoordinatorError.invalidURL(config.url)
        }

        // ws:// (integration tests) vs wss:// (production). The transport security
        // MUST match the URL scheme: pairing `.tcp` params with a wss URL makes the
        // WebSocket server-response validation fail.
        let scheme = url.scheme?.lowercased()
        let useTLS = (scheme == "wss" || scheme == "https")
        let params = useTLS ? NWParameters.tls : NWParameters.tcp

        // Disable Nagle's algorithm (TCP_NODELAY). Without this, the kernel
        // batches small WebSocket frames (~200 bytes each) and delays sending
        // until the previous segment is ACKed or enough data accumulates to
        // fill an MSS (~1460 bytes) — adding 40-200ms latency per chunk.
        // URLSessionWebSocketTask sets TCP_NODELAY internally; NWConnection
        // does not, so we must opt in. This is critical for the inference
        // hot path where each frame must leave immediately.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        params.defaultProtocolStack.transportProtocol = tcpOptions

        let wsOptions = NWProtocolWebSocket.Options()
        // Auto-reply to coordinator-initiated pings so the link stays alive without
        // hand-rolling pong replies on the receive path.
        wsOptions.autoReplyPing = true
        // Raise the inbound cap so an image/video request frame can't tear down the
        // session and collaterally cancel other in-flight requests (see the
        // constant). This is the NWProtocolWebSocket equivalent of the old
        // URLSessionWebSocketTask.maximumMessageSize.
        wsOptions.maximumMessageSize = Self.maxInboundMessageBytes
        // The legacy URLSession path issued the WebSocket upgrade with NO custom
        // HTTP headers (auth/version/wallet travel inside the `register` frame, not
        // headers), so there are none to forward via
        // `wsOptions.setAdditionalHeaders(...)` here.
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // WebSocket REQUIRES a URL endpoint: Network.framework derives host, port,
        // AND the request path (e.g. /v1/providers/ws) from it. A `.hostPort`
        // endpoint drops the path, so the handshake would issue `GET / HTTP/1.1`
        // and the coordinator's WS route would reject it.
        let connection = NWConnection(to: .url(url), using: params)
        self.nwConnection = connection
        var outboundActivation: OutboundRouter.Activation?

        // Mid-session connection drops are published here by the persistent state
        // handler and rethrown by a task-group child to drive the reconnect loop.
        let (failureStream, failureCont) = AsyncStream<Error>.makeStream()
        defer {
            failureCont.finish()
            // Tear down this connection on every exit (error OR clean reconnect),
            // so a stale NWConnection (and its internal retry) never lingers.
            // Nil the stored reference so sendOnCurrentConnection fast-returns
            // during the reconnect window instead of firing on a cancelled connection.
            self.nwConnection = nil
            // Detach the inference-chunk fast path from this connection (drops any
            // queued chunks; their requests are cancelled on disconnect). Guarded
            // by identity so a concurrent reconnect's freshly-bound writer isn't
            // clobbered by this teardown.
            self.chunkBatcher.unbind(ifCurrent: connection)
            self.resetV2NegotiationForReconnect()
            if let outboundActivation {
                self.outboundRouter.deactivate(outboundActivation)
            }
            connection.cancel()
        }

        let logger = self.logger

        // Wait for the handshake to complete (.ready). The one-shot handler set
        // here is swapped for a persistent failure-forwarding handler the instant
        // the connection is ready — done inside the `.ready` branch (serial on
        // connectionQueue) so no post-ready state change slips through the gap
        // between resuming the continuation and installing the persistent handler.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = { laterState in
                        switch laterState {
                        case .failed(let error):
                            failureCont.yield(CoordinatorError.connectionClosed(error))
                        case .waiting(let error):
                            failureCont.yield(CoordinatorError.connectionClosed(error))
                        case .cancelled:
                            failureCont.yield(CoordinatorError.connectionClosed(NWError.posix(.ECANCELED)))
                        default:
                            break
                        }
                    }
                    cont.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: CoordinatorError.connectionClosed(error))
                case .waiting(let error):
                    // Can't establish yet (DNS failure, connection refused, no
                    // route). Don't sit in NWConnection's internal wait/retry —
                    // surface it so the client's own backoff loop owns reconnect.
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: CoordinatorError.connectionClosed(error))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: CoordinatorError.connectionClosed(NWError.posix(.ECANCELED)))
                default:
                    break
                }
            }
            connection.start(queue: self.connectionQueue)
        }

        logger.info("NWConnection ready; sending registration to coordinator")

        // Negotiation is scoped to one WebSocket session. The process generation
        // remains stable, but a reconnect must receive a fresh explicit ACK.
        resetV2NegotiationForReconnect()
        try await sendRegistration(connection: connection)
        markRegistrationSucceeded()
        logger.info("Sent registration to coordinator")

        // Fresh outbound stream for THIS connection. AsyncStream is single-shot:
        // its iterator is terminated when the previous session's consumer task is
        // cancelled on disconnect, so a reused stream would never deliver another
        // message. Recreating it per connection (and routing the stable send
        // closure through outboundRouter) is what keeps attestation responses and
        // inference replies flowing after a reconnect. Activate before announcing
        // .connected so any immediate outbound is buffered, not dropped.
        let (outboundStream, outboundCont) = AsyncStream<OutboundMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.outboundBufferCapacity)
        )
        outboundActivation = outboundRouter.activate(outboundCont)

        // Bind the inference-chunk fast path to THIS connection. A per-session
        // ChunkFrameWriter (Opt 3: reused send contexts) becomes the batcher's
        // sink, so emitSSE writes chunks straight to this connection's kernel
        // buffer off a dedicated serial queue. Rebound on every reconnect;
        // detached in the defer above.
        let chunkWriter = ChunkFrameWriter(connection: connection, logger: self.logger)
        chunkBatcher.bind(connection: connection) { frames in
            chunkWriter.write(frames)
        }

        eventContinuation?.yield(.connected)

        try await sessionLoop(
            connection: connection,
            outboundStream: outboundStream,
            failureStream: failureStream
        )
    }

    internal func nextReconnectDelay() -> TimeInterval {
        reconnectBackoff.nextDelay()
    }

    internal func markRegistrationSucceeded() {
        reconnectBackoff.reset()
    }

    internal func resetV2NegotiationForReconnect() {
        if let session = v2Negotiation.session {
            v2SessionEventContinuation.yield(.ended(session))
        }
        v2Negotiation.resetForReconnect()
    }

    private func sessionLoop(
        connection: NWConnection,
        outboundStream: AsyncStream<OutboundMessage>,
        failureStream: AsyncStream<Error>
    ) async throws {
        let pingInterval: TimeInterval = 10.0
        let pongTimeout: TimeInterval = 30.0

        // Thread-safe pong timestamp: updated from the pong handler (runs on
        // connectionQueue), read from the ping task. Using an actor would force
        // structured concurrency overhead on every ping; an unfair lock is cheaper
        // for a single Instant.
        let pongTracker = PongTracker()
        let pongQueue = self.connectionQueue

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 0: Connection-failure monitor. The persistent stateUpdateHandler
            // publishes terminal connection states (.failed/.waiting/.cancelled)
            // into failureStream; rethrowing the first one tears down the whole
            // session so runLoop reconnects — even in the rare case where
            // receiveMessage has not yet surfaced the drop.
            group.addTask {
                for await error in failureStream {
                    throw error
                }
            }

            // Task 1: Receive messages from coordinator
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.receiveLoop(connection: connection)
            }

            // Task 2: Forward outbound messages to coordinator
            //
            // Hot path for inference chunks: `encodeOutbound` is nonisolated
            // (pure static codec, no actor state) so it runs inline without
            // hopping to the CoordinatorClient actor, and `sendTextFrame` is a
            // non-blocking NWConnection write — it buffers in the kernel and
            // returns immediately instead of `await`-ing each TCP ACK like the old
            // `try await ws.send(.string(...))`. That removes the per-token serial
            // stall that throttled per-stream TPS under concurrent load.
            group.addTask { [weak self] in
                guard let self else { return }
                for await msg in outboundStream {
                    if self.shutdownRequested { break }
                    guard await self.allowsOutbound(msg) else { continue }
                    let json = self.encodeOutbound(msg)
                    self.sendTextFrame(json, on: connection, identifier: "chunk")
                }
            }

            // Task 3: Heartbeat timer
            group.addTask { [weak self] in
                guard let self else { return }
                let interval = self.config.heartbeatInterval

                try await taskSleep( .seconds(interval))

                while true {
                    if self.shutdownRequested { break }
                    let json = await self.buildHeartbeatJSON()
                    self.sendTextFrame(json, on: connection, identifier: "heartbeat")
                    try await taskSleep( .seconds(interval))
                }
            }

            // Task 4: Ping timer with pong timeout + suspension detection
            group.addTask {
                var lastTick = CFAbsoluteTimeGetCurrent()
                while true {
                    try await taskSleep( .seconds(pingInterval))

                    // If far more wall-clock elapsed than we slept for, the
                    // process was suspended/throttled (App Nap or sleep). The
                    // socket is almost certainly dead and the coordinator has
                    // likely already evicted us, so reconnect NOW instead of
                    // waiting out the (also-throttled) pong timeout — this is
                    // what removes the multi-minute post-wake detection lag.
                    let now = CFAbsoluteTimeGetCurrent()
                    let gap = now - lastTick
                    lastTick = now
                    if gap > pingInterval * 3 {
                        throw CoordinatorError.suspensionDetected
                    }

                    if pongTracker.elapsed() > pongTimeout {
                        throw CoordinatorError.pongTimeout
                    }

                    // Send a WebSocket ping; the matching pong refreshes the
                    // tracker via the pong handler (invoked on connectionQueue).
                    let pingMetadata = NWProtocolWebSocket.Metadata(opcode: .ping)
                    pingMetadata.setPongHandler(pongQueue) { error in
                        if error == nil {
                            pongTracker.recordPong()
                        }
                    }
                    let pingContext = NWConnection.ContentContext(
                        identifier: "ping",
                        metadata: [pingMetadata]
                    )
                    connection.send(
                        content: nil,
                        contentContext: pingContext,
                        isComplete: true,
                        completion: .contentProcessed { _ in }
                    )
                }
            }

            // When any child finishes (normal return OR throw), cancel the
            // rest and propagate. Without cancelAll() on the normal-return path,
            // the failure-stream child would block until connectAndRun's defer
            // finishes the stream — but defer runs AFTER sessionLoop returns,
            // creating a deadlock.
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Outbound frame write (non-blocking)

    /// Fire-and-forget a pre-encoded JSON text frame on the given connection.
    ///
    /// `nonisolated` so the inference hot path (Task 2) can call it inline without
    /// hopping to the actor — keeping the per-chunk write off both the actor
    /// executor and the old await-per-ACK path is the whole point of the
    /// migration. The send is non-blocking: NWConnection buffers in the kernel and
    /// invokes the completion later; a write error is logged and the connection's
    /// state handler (Task 0) drives the reconnect.
    nonisolated internal func sendTextFrame(
        _ json: String,
        on connection: NWConnection,
        identifier: String
    ) {
        let logger = self.logger
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: identifier, metadata: [metadata])
        connection.send(
            content: Data(json.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    logger.error("WS send failed (\(identifier)): \(error.localizedDescription)")
                    // Cancel the connection immediately so the stateUpdateHandler
                    // (Task 0) fires a failure and tears down the session. Without
                    // this, the outbound loop keeps draining chunks that silently
                    // vanish, and the coordinator-side request waits for a timeout.
                    connection.cancel()
                }
            }
        )
    }

    // MARK: - Receive Loop

    private func receiveLoop(connection: NWConnection) async throws {
        while !shutdownRequested {
            // NWProtocolWebSocket delivers one complete WebSocket message per
            // receiveMessage call. Wrap the callback in a continuation so the loop
            // reads sequentially, matching the old `try await ws.receive()` shape.
            //
            // Cancellation handler: when the task group cancels this child (e.g.
            // pong timeout or suspension detected), the pending receiveMessage
            // callback won't fire until the connection is cancelled. Cancel it
            // here so the continuation unblocks and the reconnect loop proceeds
            // immediately instead of hanging until the transport times out.
            let (data, context): (Data?, NWConnection.ContentContext?) =
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { cont in
                        connection.receiveMessage { data, context, _isComplete, error in
                            if let error {
                                cont.resume(throwing: CoordinatorError.connectionClosed(error))
                                return
                            }
                            cont.resume(returning: (data, context))
                        }
                    }
                } onCancel: {
                    connection.cancel()
                }

            // Extract WS metadata for opcode inspection.
            let wsMeta =
                context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata

            // A WebSocket close frame arrives as a (typically dataless) message
            // tagged `.close`; surface it as a connection close so runLoop
            // reconnects rather than spinning on empty receives.
            if let wsMeta, wsMeta.opcode == .close {
                throw CoordinatorError.connectionClosed(NWError.posix(.ECONNRESET))
            }

            // Control frames (ping/pong) handled by autoReplyPing / the pong
            // handler carry no application payload — skip them and keep reading.
            // Only skip when WS metadata confirms a known control opcode;
            // nil/empty receives WITHOUT metadata indicate a transport-level
            // close (peer dropped TCP without a WS close frame) — surface as
            // disconnection instead of spinning in a tight loop.
            guard let data, !data.isEmpty else {
                if let wsMeta, wsMeta.opcode == .ping || wsMeta.opcode == .pong {
                    continue
                }
                // No data and no control-frame metadata → connection closed
                // without a proper WS close frame (TCP reset, intermediary drop).
                throw CoordinatorError.connectionClosed(NWError.posix(.ECONNRESET))
            }

            if wsMeta?.opcode == .binary {
                await handleIncomingBinary(data)
            } else if let text = String(data: data, encoding: .utf8) {
                await handleIncomingText(text)
            }
        }
    }

    // MARK: - Telemetry

    /// Telemetry gate: emit at counts 3, 10, then every 30.
    private func shouldEmitReconnectTelemetry(count: UInt64) -> Bool {
        count == 3 || count == 10 || count % 30 == 0
    }

    private func emitReconnectTelemetry(count: UInt64, error: Error) {
        let reachable = reachability.isReachable
        TelemetryClient.shared.emit(
            kind: .connectivity,
            severity: .warn,
            message: "coordinator reconnect",
            fields: [
                "reconnect_count": .int(Int(count)),
                "last_error": .string(error.localizedDescription),
                "coordinator_url": .string(config.url),
                // Distinguishes "coordinator down" from "box lost internet" —
                // the latter is the dominant, operator-side cause of flap.
                "network_reachable": .bool(reachable),
            ]
        )
        logger.warning(
            "Reconnect telemetry: count=\(count) network_reachable=\(reachable) error=\(error.localizedDescription)"
        )
    }
}
