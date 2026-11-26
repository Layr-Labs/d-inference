// CoordinatorClient connection lifecycle: reconnect loop with its reconnect
// policy, a single WebSocket session (ping/heartbeat/reachability), the receive
// loop with its close-code reader, and reconnect telemetry.

import Foundation
import Network
import os
import Sodium

extension CoordinatorClient {
    // MARK: - Connection Loop

    internal func runLoop() async {
        var policy = reconnectPolicy
        var reconnectCount: UInt64 = 0

        while !shutdownRequested {
            logger.info(.connectingToCoordinator)
            logger.info("Coordinator URL: \(self.config.url)")
            let session = CoordinatorSessionRecorder()

            do {
                try await connectAndRun(session)
                logger.info(.coordinatorConnectionClosed)
                // A clean close ends a final attempt too; it reconnects at once.
                memberFinalAttemptUntil = nil
                if memberRoleFailure { break }
                policy.reset()
                continue
            } catch is RegistrationRefused {
                // Not a connection failure: this Mac doesn't register at all.
                // The loop ends, and with it the event stream: the provider
                // loop ends serving and holds.
                logger.warning(.coordinatorRegistrationRefused)
                break
            } catch {
                if shutdownRequested || memberRoleFailure { break }

                // Placed before the event: a waiting member reads the
                // attempt's outcome when it sees the disconnect.
                let end = session.end()
                let delay = nextMemberAwareReconnectDelay(
                    backoff: TimeInterval.random(in: policy.nextDelayRange(after: end)))
                DecodeRateIdleAge.coordinatorDecays.reset()
                eventContinuation?.yield(.disconnected)
                let reachable = reachability.isReachable
                let closeCode = end.closeCode.map { "\($0)" } ?? "none"
                logger.warning(.coordinatorConnectionFailed)
                logger.warning("Coordinator connection error: \(error.localizedDescription). network_reachable=\(reachable). close_code=\(closeCode). Reconnecting in \(delay)s")

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

        logger.info(.coordinatorClientShutdown)
        eventContinuation?.finish()
    }

    // MARK: - Single Connection Session

    /// Transport stack for one coordinator connection: TCP, TLS for a
    /// `wss`/`https` URL, and the WebSocket protocol on top.
    static func connectionParameters(for url: URL) -> NWParameters {
        // ws:// (integration tests) vs wss:// (production). The transport security
        // MUST match the URL scheme: pairing `.tcp` params with a wss URL makes the
        // WebSocket server-response validation fail.
        let scheme = url.scheme?.lowercased()
        let useTLS = (scheme == "wss" || scheme == "https")
        // A debug build may pin a local test coordinator's certificate
        // (`CoordinatorDebugCertificatePin`); release builds always use the
        // system's trust evaluation.
        let params = useTLS
            ? (CoordinatorDebugCertificatePin.tlsOptions().map { NWParameters(tls: $0) } ?? NWParameters.tls)
            : NWParameters.tcp

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
        // HTTP headers (auth/version travel inside the `register` frame, not
        // headers), so there are none to forward via
        // `wsOptions.setAdditionalHeaders(...)` here.
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return params
    }

    private func connectAndRun(_ session: CoordinatorSessionRecorder) async throws {
        guard let url = URL(string: config.url) else {
            throw CoordinatorError.invalidURL(config.url)
        }
        // Before connecting, so the coordinator never waits on it: what this
        // connection registers about the Mac (the provider loop reads Secure
        // Boot again here while it is unread). A refusal ends the attempt, and
        // a shutdown during it ends the attempt before any socket opens.
        if let refresh = registrationPrivacyRefresh {
            let refreshed = try await refresh()
            guard !shutdownRequested else { throw CancellationError() }
            if let refreshed { refreshedPrivacyCapabilities = refreshed }
        }

        // WebSocket REQUIRES a URL endpoint: Network.framework derives host, port,
        // AND the request path (e.g. /v1/providers/ws) from it. A `.hostPort`
        // endpoint drops the path, so the handshake would issue `GET / HTTP/1.1`
        // and the coordinator's WS route would reject it.
        let connection = NWConnection(to: .url(url), using: Self.connectionParameters(for: url))
        self.nwConnection = connection
        self.appAttestResumeNonce = appAttestResumeResponder == nil ? nil
            : Data(Sodium().randomBytes.buf(length: 32)!).base64EncodedString()
        self.appAttestResumeAnswered = false

        // Mid-session connection drops are published here by the persistent state
        // handler and rethrown by a task-group child to drive the reconnect loop.
        let (failureStream, failureCont) = AsyncStream<Error>.makeStream()
        var memberTimeout: Task<Void, Never>?
        defer {
            memberTimeout?.cancel()
            failureCont.finish()
            // Before the reconnect loop announces the end: a waiting member
            // past its deadline must not wait on a connection that is gone.
            self.noteMemberAttemptEnded()
            // Tear down this connection on every exit (error OR clean reconnect),
            // so a stale NWConnection (and its internal retry) never lingers.
            // Nil the stored reference so sendOnCurrentConnection fast-returns
            // during the reconnect window instead of firing on a cancelled connection.
            self.nwConnection = nil
            self.appAttestResumeNonce = nil
            self.appAttestResumeAnswered = false
            // Routing v2: this connection's capacity-seq session is over. A
            // reconnect re-registers and restarts seq at 1; the published
            // quote snapshot is dropped with it so quotes never answer from a
            // session the new coordinator connection has not seen.
            self.sessionRegistered = false
            // One negotiation per connection: a late prior acknowledgment must
            // never open the next connection's member wait.
            self.memberNegotiation = nil
            // No grant or key is retained across a connection boundary.
            self.detachNativePairMember()
            self.failDrainBarriers()
            self.failModelReplacements()
            // Nothing is registered once the connection is gone.
            self.state.registeredModelIDs = nil
            self.state.resetCapacitySession()
            // Detach the inference-chunk fast path from this connection (drops any
            // queued chunks; their requests are cancelled on disconnect). Guarded
            // by identity so a concurrent reconnect's freshly-bound writer isn't
            // clobbered by this teardown.
            self.chunkBatcher.unbind(ifCurrent: connection)
            connection.cancel()
        }

        let logger = self.logger

        // Wait for the handshake to complete (.ready), bounded by the
        // handshake deadline. The persistent failure-forwarding handler is
        // installed inside the `.ready` callback (serial on connectionQueue) so
        // no post-ready state change slips through the gap between resuming
        // and installing it.
        noteMemberAttemptStarted()
        do {
            try await CoordinatorConnectionHandshake.start(
                connection, on: connectionQueue, timeout: config.handshakeTimeout
            ) {
                connection.stateUpdateHandler = { laterState in
                    if let error = CoordinatorError(terminalState: laterState) {
                        failureCont.yield(error)
                    }
                }
            }
        } catch {
            // Not reached at all: a waiting member says so instead of
            // reporting a role refusal (F11).
            noteMemberAttemptUnreachable(error)
            throw error
        }

        logger.info(.coordinatorTransportReady)
        coordinatorConnectionReport = CoordinatorServerPin.observe(connection, url: url, logger: logger)

        // A member registration carries this connection's fresh negotiation
        // nonce; the coordinator's acceptance must echo it within the
        // negotiation window (ten seconds in production).
        memberNegotiation = config.executionRole == .clusterMember
            ? .init(window: config.memberNegotiationWindow) : nil
        memberOrdinaryAnswer = false
        noteMemberTransportReady(memberNegotiation)
        if let negotiation = memberNegotiation {
            memberTimeout = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: negotiation.deadline) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.expireMemberNegotiation(nonce: negotiation.nonce)
            }
        }
        guard !shutdownRequested else { throw CancellationError() }
        try await sendRegistration(connection: connection)
        logger.info(.coordinatorRegistrationSent)
        // Fresh capacity-seq session for this connection (routing v2): seq
        // restarts at 1 on the first heartbeat and out-of-band event
        // heartbeats are permitted from here on.
        state.resetCapacitySession()
        sessionRegistered = config.executionRole == .solo
        // The reconnect policy measures how long the session stays open from here.
        session.markOpened()

        // Fresh outbound stream for THIS connection. AsyncStream is single-shot:
        // its iterator is terminated when the previous session's consumer task is
        // cancelled on disconnect, so a reused stream would never deliver another
        // message. Recreating it per connection (and routing the stable send
        // closure through outboundRouter) is what keeps attestation responses and
        // inference replies flowing after a reconnect. Activate before announcing
        // .connected so any immediate outbound is buffered, not dropped.
        let (outboundStream, outboundCont) = AsyncStream<OutboundMessage>.makeStream()
        failDrainBarriers()
        outboundRouter.activate(outboundCont)

        // Bind the inference-chunk fast path to THIS connection. A per-session
        // ChunkFrameWriter (Opt 3: reused send contexts) becomes the batcher's
        // sink, so emitSSE writes chunks straight to this connection's kernel
        // buffer off a dedicated serial queue. Rebound on every reconnect;
        // detached in the defer above.
        let chunkWriter = ChunkFrameWriter(connection: connection, logger: self.logger)
        chunkBatcher.bind(connection: connection) { frames in
            chunkWriter.write(frames)
        }

        // A member connection is announced only by its nonce-bound acceptance
        // (CoordinatorClient+Inbound), never by the registration send.
        if config.executionRole == .solo { eventContinuation?.yield(.connected) }

        try await sessionLoop(
            connection: connection,
            outboundStream: outboundStream,
            failureStream: failureStream,
            session: session
        )
    }

    private func sessionLoop(
        connection: NWConnection,
        outboundStream: AsyncStream<OutboundMessage>,
        failureStream: AsyncStream<Error>,
        session: CoordinatorSessionRecorder
    ) async throws {
        let liveness = self.linkLiveness
        // Time of the last inbound frame: updated on connectionQueue by the pong
        // handler and the receive callback, read by the ping task. An unfair
        // lock is cheaper than an actor hop for a single Instant.
        let start = ContinuousClock.now
        let activity = LinkActivityTracker(start: start)
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
                try await self.receiveLoop(connection: connection, session: session, activity: activity)
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
                    let json = self.encodeOutbound(msg)
                    self.sendTextFrame(json, on: connection, identifier: "chunk",
                                       onWritten: msg.onWritten ?? self.registeredSetUpdate(msg))
                }
            }

            // Task 3: Heartbeat timer
            group.addTask { [weak self] in
                guard let self else { return }
                let interval = self.config.heartbeatInterval

                try await taskSleep( .seconds(interval))

                while true {
                    if self.shutdownRequested { break }
                    await self.sendBaselineHeartbeat(on: connection)
                    try await taskSleep( .seconds(interval))
                }
            }

            // Task 4: Ping timer with the dead-link bound and suspension
            // detection (CoordinatorLinkLiveness). A silent link, such as one
            // whose node was hard-reset, ends with no close frame and no TCP
            // reset; this task is what notices it.
            group.addTask {
                var watch = CoordinatorLinkWatch(liveness: liveness, start: start)
                while true {
                    try await taskSleep(liveness.pingInterval)

                    let lastInbound = activity.lastInbound
                    switch watch.check(now: .now, lastInbound: lastInbound) {
                    case .alive:
                        break
                    case .dead:
                        await Self.sendLinkClose(.silentLink, on: connection)
                        throw CoordinatorError.pongTimeout(after: watch.silenceBound(lastInbound: lastInbound))
                    case .suspended:
                        // Sleep or a long suspension: the coordinator has
                        // probably dropped the session, so reconnect once now.
                        await Self.sendLinkClose(.suspended, on: connection)
                        throw CoordinatorError.suspensionDetected
                    }

                    // Send a WebSocket ping; the matching pong refreshes the
                    // tracker via the pong handler (invoked on connectionQueue).
                    let pingMetadata = NWProtocolWebSocket.Metadata(opcode: .ping)
                    pingMetadata.setPongHandler(pongQueue) { error in
                        if error == nil {
                            activity.recordInbound()
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
            defer { group.cancelAll() }
            try await group.next()
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
        identifier: String,
        onWritten: (@Sendable () -> Void)? = nil
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
                    logger.error(.coordinatorSendFailed)
                    logger.error("WS send failed (\(identifier)): \(error.localizedDescription)")
                    // Cancel the connection immediately so the stateUpdateHandler
                    // (Task 0) fires a failure and tears down the session. Without
                    // this, the outbound loop keeps draining chunks that silently
                    // vanish, and the coordinator-side request waits for a timeout.
                    connection.cancel()
                } else {
                    onWritten?()
                }
            }
        )
    }

    /// Sends a close frame with `code` and returns when it has been handed to
    /// the transport, or after `limit` on a link that takes nothing more. The
    /// caller then tears the session down: the coordinator records the code
    /// (`ws_close_4001`, `ws_close_4002`) when the frame reaches it.
    static func sendLinkClose(
        _ code: CoordinatorLinkCloseCode, on connection: NWConnection, within limit: Duration = .milliseconds(500)
    ) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(code.rawValue)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce = { @Sendable in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume() }
            }
            connection.send(content: nil, contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in resumeOnce() })
            let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { resumeOnce() }
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop(
        connection: NWConnection, session: CoordinatorSessionRecorder, activity: LinkActivityTracker
    ) async throws {
        // The connection is read on its own queue (`CoordinatorFrameReader`),
        // not after each message is handled here: handling waits on this actor,
        // and a socket left unread meanwhile stops delivering pongs and frames.
        let frames = CoordinatorFrameReader.frames(on: connection, session: session, activity: activity)
        for try await frame in frames {
            if shutdownRequested { return }
            guard !Task.isCancelled, nwConnection === connection else { throw CancellationError() }
            await handleIncomingFrame(
                frame.data, receivedAt: frame.receivedAt, profileAnchor: frame.profileAnchor,
                connection: connection)
        }
        if shutdownRequested { return }
        throw CancellationError()
    }

    /// What one received WebSocket message (other than a close frame) is to
    /// the session. Pings and pongs are answered by autoReplyPing / the pong
    /// handler and are never application messages, whatever their payload: the
    /// coordinator's transport probe pings with a counter ("1", "2", …) every
    /// 30 s. Only a confirmed control opcode is skipped; no data and no control
    /// opcode means the peer dropped the transport without a close frame (TCP
    /// reset, intermediary drop), surfaced as a disconnection instead of
    /// spinning in a tight loop.
    static func inboundFrame(data: Data?, opcode: NWProtocolWebSocket.Opcode?) -> CoordinatorInboundFrame {
        if opcode == .ping || opcode == .pong { return .control }
        guard let data, !data.isEmpty else { return .transportClosed }
        return .message(data)
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
        logger.warning("Reconnect telemetry: count=\(count) network_reachable=\(reachable) error=\(error.localizedDescription)")
    }
}

extension NWProtocolWebSocket.CloseCode {
    /// The close code number as sent on the wire, for every case that
    /// Network.framework reports.
    var wireValue: UInt16? {
        switch self {
        case .protocolCode(let code):
            return code.rawValue
        case .applicationCode(let code), .privateCode(let code):
            return code
        @unknown default:
            return nil
        }
    }
}

extension NWProtocolWebSocket.Metadata {
    /// The status code of this close frame as the peer sent it.
    ///
    /// `closeCode` names only the codes that Network.framework knows. It reports
    /// other codes, such as 1012 (service restart), as `noStatusReceived`, but it
    /// delivers the frame's payload as the message content. The payload starts
    /// with the code in network byte order (RFC 6455, section 5.5.1), so the code
    /// is read from the content in that case.
    func sentCloseCode(content: Data?) -> UInt16? {
        let reported = closeCode.wireValue
        let noStatus = NWProtocolWebSocket.CloseCode.Defined.noStatusReceived.rawValue
        guard reported == nil || reported == noStatus, let content, content.count >= 2 else {
            return reported
        }
        let high = content[content.startIndex]
        let low = content[content.index(after: content.startIndex)]
        return UInt16(high) << 8 | UInt16(low)
    }
}
