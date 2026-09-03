import Darwin
import Foundation
import SandboxGuestProtocol

/// Serves one broker connection, independent of how the connection was made.
///
/// The transport is `AF_VSOCK` in production, but nothing here depends on that,
/// which is what lets both halves of the protocol be exercised against each
/// other over a socketpair on a host where vsock cannot exist.
public struct SandboxGuestAgentSession: Sendable {
    public struct Configuration: Sendable {
        public let agentVersion: String
        public let imageID: String
        /// Whether a well-formed command may actually be executed. A property
        /// of the image, set when it is baked; a request is answered with a
        /// typed failure instead when it is off.
        public let executionEnabled: Bool

        /// Environment variable the LaunchDaemon plist carries to say whether
        /// this image was baked to run commands.
        public static let executionEnvironmentVariable =
            "DARKBLOOM_GUEST_ALLOW_EXECUTION"
        /// Environment variable carrying the image id the host handshakes on.
        public static let imageIDEnvironmentVariable =
            "DARKBLOOM_GUEST_IMAGE_ID"

        /// Reads the executor flag from a process environment.
        ///
        /// Only an exact `"1"` enables execution. A permissive parse -- any
        /// non-empty value, or a `Bool` cast that reads "false" as absent --
        /// would turn a typo in a plist into an executing image, and this is
        /// the flag that decides whether a guest runs tenant code at all. An
        /// image baked before the variable existed has no value here and
        /// correctly reads as refusing.
        public static func executionEnabled(
            in environment: [String: String]
        ) -> Bool {
            environment[executionEnvironmentVariable] == "1"
        }
        /// Home directory forced onto every command, overriding anything the
        /// caller supplies. Becomes the unprivileged sandbox user's home once
        /// that account exists.
        public let guestHome: String

        public init(
            agentVersion: String,
            imageID: String,
            executionEnabled: Bool = false,
            // No default: this becomes HOME for every command the agent
            // spawns, and the literal that used to be here named an account
            // that per-sandbox identities stopped creating.
            guestHome: String
        ) {
            self.agentVersion = agentVersion
            self.imageID = imageID
            self.executionEnabled = executionEnabled
            self.guestHome = guestHome
        }
    }

    private static let readChunkBytes = 64 * 1024
    private static let maximumInboundBuffer =
        SandboxGuestFrameCodec.maximumPayloadBytes
        + SandboxGuestFrameCodec.headerBytes

    public let configuration: Configuration
    private let log: @Sendable (String) -> Void

    public init(
        configuration: Configuration,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.log = log
    }

    /// Runs until the peer closes or the conversation must be abandoned.
    /// Does not close `descriptor`; the caller owns it.
    public func serve(descriptor: Int32) {
        // Say up front whether commands will be served. The host uses it to
        // pick a transport, so an agent that refuses everything sends the host
        // back to SSH instead of collecting a refusal per command.
        let handshake = SandboxGuestHandshake(
            agentVersion: configuration.agentVersion,
            imageID: configuration.imageID,
            executionEnabled: configuration.executionEnabled
        )
        guard let payload = try? JSONEncoder().encode(handshake),
              send(
                  SandboxGuestFrame(kind: .handshake, payload: payload),
                  to: descriptor
              )
        else {
            log("handshake write failed (errno \(errno))")
            return
        }

        var inbound = Data()
        var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)

        while true {
            let received = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                while true {
                    let result = read(descriptor, base, raw.count)
                    if result < 0 && errno == EINTR { continue }
                    return result
                }
            }
            if received < 0 {
                log("read failed (errno \(errno))")
                return
            }
            if received == 0 {
                log("peer closed the channel")
                return
            }
            inbound.append(contentsOf: chunk.prefix(received))

            // The codec caps a declared frame; a peer that never completes one
            // must not be able to grow this without bound.
            guard inbound.count <= Self.maximumInboundBuffer else {
                log("inbound buffer exceeded the frame limit")
                return
            }

            while true {
                let frame: SandboxGuestFrame?
                do {
                    frame = try SandboxGuestFrameCodec.decode(from: &inbound)
                } catch {
                    log("refusing malformed frame: \(error)")
                    sendFailure(
                        code: "malformed_frame",
                        message: "\(error)",
                        to: descriptor
                    )
                    return
                }
                guard let frame else { break }
                if !handle(frame: frame, on: descriptor) {
                    return
                }
            }
        }
    }

    /// Returns false when the connection should be closed.
    private func handle(frame: SandboxGuestFrame, on descriptor: Int32) -> Bool {
        switch frame.kind {
        case .commandRequest:
            guard let wire = try? JSONDecoder().decode(
                SandboxGuestCommandWire.self,
                from: frame.payload
            ) else {
                sendFailure(
                    code: "malformed_request",
                    message: "command request could not be decoded",
                    to: descriptor
                )
                return true
            }
            guard wire.isWellFormed else {
                sendFailure(
                    code: "invalid_request",
                    message: "command request failed guest-side validation",
                    to: descriptor
                )
                return true
            }
            guard configuration.executionEnabled else {
                log("refusing command \(wire.idempotencyKey): execution is not enabled")
                sendFailure(
                    code: "execution_disabled",
                    message: "guest execution is not enabled until randomized "
                        + "bootstrap credentials and an unprivileged sandbox "
                        + "user are in place",
                    to: descriptor
                )
                return true
            }
            let executor = SandboxGuestCommandExecutor(
                home: configuration.guestHome
            )
            let envelope = executor.execute(wire)
            guard envelope.isSelfConsistent,
                  let payload = try? JSONEncoder().encode(envelope)
            else {
                // Refusing to emit an envelope the host would reject is better
                // than emitting one it cannot decode.
                log("produced an inconsistent envelope for \(wire.idempotencyKey)")
                sendFailure(
                    code: "invalid_result",
                    message: "the agent produced an envelope that fails its own invariants",
                    to: descriptor
                )
                return true
            }
            // A partial write leaves a truncated frame on the wire, so the
            // connection must close rather than continue on a stream the host
            // can no longer parse.
            guard send(
                SandboxGuestFrame(kind: .commandResult, payload: payload),
                to: descriptor
            ) else {
                log("result write failed for \(wire.idempotencyKey)")
                return false
            }
            return true

        case .handshake, .commandResult, .failure:
            // Agent-to-host kinds. Receiving one means the peer is not a
            // Darkbloom broker, so fail closed rather than guessing.
            log("refusing host-inbound frame of kind \(frame.kind)")
            sendFailure(
                code: "unexpected_frame",
                message: "frame kind \(frame.kind) is not valid from the host",
                to: descriptor
            )
            return false
        }
    }

    // MARK: - Writing

    private func sendFailure(code: String, message: String, to descriptor: Int32) {
        guard let payload = try? JSONEncoder().encode(
            SandboxGuestFailure(code: code, message: message)
        ) else {
            return
        }
        _ = send(
            SandboxGuestFrame(kind: .failure, payload: payload),
            to: descriptor
        )
    }

    private func send(_ frame: SandboxGuestFrame, to descriptor: Int32) -> Bool {
        guard let encoded = try? SandboxGuestFrameCodec.encode(frame) else {
            return false
        }
        var offset = 0
        return encoded.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while offset < buffer.count {
                let written = write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
    }
}
