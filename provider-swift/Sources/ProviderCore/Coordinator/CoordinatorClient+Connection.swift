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
        var backoff = ExponentialBackoff(base: 1.0, max: 30.0)
        var reconnectCount: UInt64 = 0

        while !shutdownRequested {
            logger.info("Connecting to coordinator: \(self.config.url)")

            do {
                try await connectAndRun()
                logger.info("Coordinator connection closed, reconnecting...")
                backoff.reset()
                continue
            } catch {
                if shutdownRequested { break }

                eventContinuation?.yield(.disconnected)
                let delay = backoff.nextDelay()
                let reachable = reachability.isReachable
                logger.warning("Coordinator connection error: \(error.localizedDescription). network_reachable=\(reachable). Reconnecting in \(delay)s")

                reconnectCount += 1
                if shouldEmitReconnectTelemetry(count: reconnectCount) {
                    emitReconnectTelemetry(count: reconnectCount, error: error)
                }

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    // Task cancelled = shutdown
                    break
                }
            }
        }

        logger.info("Coordinator client shut down")
        eventContinuation?.finish()
    }

    // MARK: - Single Connection Session

    private func connectAndRun() async throws {
        guard let url = URL(string: config.url) else {
            throw CoordinatorError.invalidURL(config.url)
        }

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let ws = session.webSocketTask(with: url)
        // Raise the inbound cap so an image/video request frame can't tear down the
        // session and collaterally cancel other in-flight requests (see the constant).
        Self.applyInboundMessageLimit(to: ws)
        self.webSocketTask = ws
        ws.resume()

        try await sendRegistration(ws: ws)
        logger.info("Sent registration to coordinator")

        // Fresh outbound stream for THIS connection. AsyncStream is single-shot:
        // its iterator is terminated when the previous session's consumer task is
        // cancelled on disconnect, so a reused stream would never deliver another
        // message. Recreating it per connection (and routing the stable send
        // closure through outboundRouter) is what keeps attestation responses and
        // inference replies flowing after a reconnect. Activate before announcing
        // .connected so any immediate outbound is buffered, not dropped.
        let (outboundStream, outboundCont) = AsyncStream<OutboundMessage>.makeStream()
        outboundRouter.activate(outboundCont)

        eventContinuation?.yield(.connected)

        try await sessionLoop(ws: ws, outboundStream: outboundStream)
    }

    private func sessionLoop(
        ws: URLSessionWebSocketTask,
        outboundStream: AsyncStream<OutboundMessage>
    ) async throws {
        let pingInterval: TimeInterval = 10.0
        let pongTimeout: TimeInterval = 30.0

        // Thread-safe pong timestamp: updated from sendPing's callback (arbitrary queue),
        // read from the ping task. Using an actor would force structured concurrency
        // overhead on every ping; an unfair lock is cheaper for a single Instant.
        let pongTracker = PongTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Receive messages from coordinator
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.receiveLoop(ws: ws)
            }

            // Task 2: Forward outbound messages to coordinator
            group.addTask { [weak self] in
                guard let self else { return }
                for await msg in outboundStream {
                    let shutting = await self.shutdownRequested
                    if shutting { break }
                    let json = await self.encodeOutbound(msg)
                    try await ws.send(.string(json))
                }
            }

            // Task 3: Heartbeat timer
            group.addTask { [weak self] in
                guard let self else { return }
                let interval = await self.config.heartbeatInterval

                try await Task.sleep(for: .seconds(interval))

                while true {
                    let shutting = await self.shutdownRequested
                    if shutting { break }
                    let json = await self.buildHeartbeatJSON()
                    try await ws.send(.string(json))
                    try await Task.sleep(for: .seconds(interval))
                }
            }

            // Task 4: Ping timer with pong timeout + suspension detection
            group.addTask {
                var lastTick = CFAbsoluteTimeGetCurrent()
                while true {
                    try await Task.sleep(for: .seconds(pingInterval))

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

                    ws.sendPing { error in
                        if error == nil {
                            pongTracker.recordPong()
                        }
                    }
                }
            }

            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop(ws: URLSessionWebSocketTask) async throws {
        while !shutdownRequested {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                throw CoordinatorError.connectionClosed(error)
            }

            switch message {
            case .string(let text):
                await handleIncomingText(text, ws: ws)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    await handleIncomingText(text, ws: ws)
                }
            @unknown default:
                break
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
        logger.warning("Reconnect telemetry: count=\(count) network_reachable=\(reachable) error=\(error.localizedDescription)")
    }
}
