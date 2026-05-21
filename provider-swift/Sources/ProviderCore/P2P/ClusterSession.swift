import CryptoKit
import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - ClusterSessionConfig

public struct ClusterSessionConfig: Sendable {
    /// IP address of rank 1 (the peer, from cluster setup config).
    public let peerIP: String
    /// Port rank 1 listens on.
    public let port: UInt16
    /// How often to send health pings (seconds).
    public let pingInterval: TimeInterval
    /// Missed pings before marking unavailable.
    public let maxMissedPings: Int
    /// Timeout on each ping response (seconds).
    public let pingTimeout: TimeInterval
    /// Delay between auto-reconnect attempts (seconds).
    public let reconnectInterval: TimeInterval

    public init(
        peerIP: String,
        port: UInt16 = 7777,
        pingInterval: TimeInterval = 5,
        maxMissedPings: Int = 3,
        pingTimeout: TimeInterval = 3,
        reconnectInterval: TimeInterval = 10
    ) {
        self.peerIP = peerIP
        self.port = port
        self.pingInterval = pingInterval
        self.maxMissedPings = maxMissedPings
        self.pingTimeout = pingTimeout
        self.reconnectInterval = reconnectInterval
    }
}

// MARK: - ClusterSession

/// Manages the lifecycle of a secure cluster session between rank 0 and rank 1.
///
/// Rank 0 creates this actor and calls `start()`. It handles:
///   - SE mutual authentication + ephemeral X25519 session key establishment
///   - Background health ping loop (every 5s)
///   - Auto-reconnect with fresh handshake on link loss
///   - Exposes `health` and `sessionKey` for use by EncryptedPipelineEngine
public actor ClusterSession {
    private let config: ClusterSessionConfig
    private let signer: any AttestationSigner

    private var _health: ClusterHealth = .unavailable
    private var _sessionKey: SymmetricKey?
    private var _connection: ThunderboltConnection?
    private var _peerStatus: PongPayload?
    private var _inferenceInFlight: Bool = false

    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "ClusterSession")

    public init(config: ClusterSessionConfig, signer: any AttestationSigner) {
        self.config = config
        self.signer = signer
    }

    // MARK: - Public API

    public var health: ClusterHealth { _health }

    /// The current session key. Throws if the session is not ready.
    public func sessionKey() throws -> SymmetricKey {
        guard case .ready = _health, let key = _sessionKey else {
            throw ClusterError.notReady(_health)
        }
        return key
    }

    /// The last known peer status (model loaded, memory pressure, etc.)
    public var peerStatus: PongPayload? { _peerStatus }

    /// The active connection for sending inference frames. Throws if not ready.
    public func connection() throws -> ThunderboltConnection {
        guard case .ready = _health, let conn = _connection else {
            throw ClusterError.notReady(_health)
        }
        return conn
    }

    /// Mark inference as in-flight (pauses pings during inference).
    public func setInferenceInFlight(_ value: Bool) {
        _inferenceInFlight = value
    }

    // MARK: - Start

    /// Connect to rank 1, run handshake, start ping loop and reconnect loop.
    /// Returns immediately after first successful connection; background tasks keep running.
    public func start() async {
        await connectLoop()
    }

    // MARK: - Connection loop

    private func connectLoop() async {
        while true {
            do {
                logger.info("Connecting to rank 1 at \(self.config.peerIP):\(self.config.port)…")
                let conn = try await ThunderboltLink.connect(to: config.peerIP, port: config.port)

                logger.info("TCP connected. Running handshake…")
                let key = try await ClusterHandshake.performAsRank0(
                    connection: conn,
                    signer: signer,
                    peerIP: config.peerIP
                )

                // Session established.
                _connection = conn
                _sessionKey = key
                _health = .degraded(missedPings: 0)  // set ready on first pong
                logger.info("Handshake complete. Session key derived. Starting ping loop.")

                // Ping loop runs until connection breaks.
                await pingLoop(conn: conn)

                // If we get here, ping loop exited — connection lost.
            } catch {
                logger.warning("Connection/handshake failed: \(error). Retrying in \(self.config.reconnectInterval)s.")
            }

            // Zero old key before retrying.
            _sessionKey = nil
            _connection = nil
            _health = .unavailable

            try? await Task.sleep(for: .seconds(config.reconnectInterval))
        }
    }

    // MARK: - Ping loop

    private func pingLoop(conn: ThunderboltConnection) async {
        var missedPings = 0

        while true {
            try? await Task.sleep(for: .seconds(config.pingInterval))

            // Skip pings during active inference — the inference itself monitors the link.
            if _inferenceInFlight { continue }

            do {
                let pong = try await sendPing(conn: conn)
                _peerStatus = pong
                missedPings = 0
                _health = pong.modelLoaded ? .ready : .degraded(missedPings: 0)
            } catch {
                missedPings += 1
                logger.warning("Ping missed (\(missedPings)/\(self.config.maxMissedPings)): \(error)")
                _health = .degraded(missedPings: missedPings)

                if missedPings >= config.maxMissedPings {
                    logger.error("Peer unreachable after \(missedPings) missed pings. Tearing down session.")
                    _health = .unavailable
                    conn.cancel()
                    return
                }
            }
        }
    }

    private func sendPing(conn: ThunderboltConnection) async throws -> PongPayload {
        guard let key = _sessionKey else { throw ClusterError.notReady(_health) }

        let pingFrame = ClusterFrame.encode(type: .ping)
        let sealedPing = try ClusterLinkSeal.seal(pingFrame, key: key)
        try await conn.send(sealedPing)

        // Wait for pong with a timeout.
        let sealedPong = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await conn.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(self.config.pingTimeout))
                throw ClusterError.inferenceTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        let pongFrame = try ClusterLinkSeal.open(sealedPong, key: key)

        guard try ClusterFrame.decodeType(from: pongFrame) == .pong else {
            throw ClusterError.unexpectedMessage(expected: .pong, got: try ClusterFrame.decodeType(from: pongFrame))
        }
        return try ClusterFrame.decodeJSON(PongPayload.self, from: pongFrame)
    }
}

// MARK: - ClusterPeer (rank 1 side)

/// Rank 1 listens for rank 0's connection, runs handshake, then responds to pings
/// and serves inference frames indefinitely. Call `serve(modelState:inferenceHandler:)`
/// from the main inference loop on rank 1.
public final class ClusterPeer: @unchecked Sendable {
    private let port: UInt16
    private let signer: any AttestationSigner
    private let peerIP: String  // rank 0's IP for pinning

    private var sessionKey: SymmetricKey?
    private var connection: ThunderboltConnection?

    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "ClusterPeer")

    public init(port: UInt16 = 7777, signer: any AttestationSigner, peerIP: String) {
        self.port = port
        self.signer = signer
        self.peerIP = peerIP
    }

    // MARK: - Start

    /// Listen for rank 0, accept exactly one connection, run handshake, then serve.
    ///
    /// - Parameters:
    ///   - modelState: Called on every incoming ping; returns the current health payload.
    ///   - inferenceHandler: Called for `promptTokens`, `stepToken`, and `sessionStop`
    ///     frames — the live TP inference frames produced during a generation request.
    ///     Receives the connection, session key, and the raw frame data.
    ///   - bootstrapHandler: Called for the `jacclBootstrap` frame that rank 0 sends
    ///     immediately after the SE handshake completes. Separated from `inferenceHandler`
    ///     so the jaccl bootstrap path can be wired independently of the TP engine.
    public func serve(
        modelState: @Sendable @escaping () -> PongPayload,
        inferenceHandler: @Sendable @escaping (ThunderboltConnection, SymmetricKey, Data) async throws -> Void,
        bootstrapHandler: @Sendable @escaping (ThunderboltConnection, SymmetricKey, Data) async throws -> Void
    ) async throws {
        let listener = try ThunderboltLink.listen(on: port) { [weak self] conn in
            guard let self else { return }
            Task {
                await self.handleConnection(
                    conn,
                    modelState: modelState,
                    inferenceHandler: inferenceHandler,
                    bootstrapHandler: bootstrapHandler
                )
            }
        }
        // Keep listener alive indefinitely.
        _ = listener
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }

    private func handleConnection(
        _ conn: ThunderboltConnection,
        modelState: @Sendable @escaping () -> PongPayload,
        inferenceHandler: @Sendable @escaping (ThunderboltConnection, SymmetricKey, Data) async throws -> Void,
        bootstrapHandler: @Sendable @escaping (ThunderboltConnection, SymmetricKey, Data) async throws -> Void
    ) async {
        do {
            logger.info("Rank 0 connected. Running handshake.")
            let key = try await ClusterHandshake.performAsRank1(
                connection: conn,
                signer: signer,
                peerIP: peerIP
            )
            logger.info("Handshake complete. Serving messages.")
            sessionKey = key
            connection = conn

            // Message dispatch loop. Every post-handshake frame is sealed at
            // the link layer with AES-256-GCM via ClusterLinkSeal; unwrap on
            // receive so the rest of this loop sees plaintext ClusterFrame
            // bytes (type byte + payload).
            while true {
                let sealedFrame = try await conn.receive()
                let frame: Data
                do {
                    frame = try ClusterLinkSeal.open(sealedFrame, key: key)
                } catch {
                    logger.warning("Link-layer unseal failed (tamper / wrong key): \(error)")
                    conn.cancel()
                    return
                }
                let msgType = try ClusterFrame.decodeType(from: frame)

                switch msgType {
                case .ping:
                    let status = modelState()
                    let pongFrame = try ClusterFrame.encodeJSON(type: .pong, value: status)
                    let sealedPong = try ClusterLinkSeal.seal(pongFrame, key: key)
                    try await conn.send(sealedPong)

                case .jacclBootstrap:
                    // Dedicated handler — jaccl bootstrap runs before the TP engine is
                    // wired up and must not share the inferenceHandler path.
                    try await bootstrapHandler(conn, key, frame)

                case .promptTokens, .stepToken, .sessionStop, .inferenceStep, .inferenceToken,
                     .ppActivation, .ppToken, .ppSessionEnd:
                    // Live TP/PP inference frames — dispatched to the active engine's handler.
                    try await inferenceHandler(conn, key, frame)

                case .sessionEnd:
                    logger.info("Rank 0 sent sessionEnd. Closing.")
                    conn.cancel()
                    return

                default:
                    logger.warning("Unexpected message type \(msgType.rawValue), ignoring.")
                }
            }
        } catch {
            logger.warning("Connection closed: \(error)")
            conn.cancel()
        }
    }
}
