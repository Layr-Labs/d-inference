import Darwin
import Foundation
import SandboxGuestProtocol

// Guest-side agent for the vsock channel established by Lume patch 0005.
//
// It binds AF_VSOCK inside the guest, announces a versioned identity, and
// speaks the framed protocol in SandboxGuestProtocol. Command execution is not
// wired up yet: a well-formed request is answered with a typed failure rather
// than being run, because carrying tenant work also requires randomized
// bootstrap credentials and an unprivileged sandbox user. Until both exist,
// executing here would be exactly the boundary the host is refusing to cross.
//
// AF_VSOCK sockets can only be created inside a virtual machine. On a host this
// exits immediately with ENODEV, which is documented behaviour and a useful
// smoke check.

private enum AgentDefaults {
    static let port: UInt32 = 8_888
    static let agentVersion = "0.1.0"
    static let backlog: Int32 = 4
    static let readChunkBytes = 64 * 1024
    static let maximumInboundBuffer = SandboxGuestFrameCodec.maximumPayloadBytes
        + SandboxGuestFrameCodec.headerBytes
}

private func fail(_ message: String, code: Int32 = 70) -> Never {
    FileHandle.standardError.write(Data("darkbloom-guest-agent: \(message)\n".utf8))
    exit(code)
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("darkbloom-guest-agent: \(message)\n".utf8))
}

private func resolvePort() -> UInt32 {
    let environment = ProcessInfo.processInfo.environment
    let arguments = CommandLine.arguments
    let raw = arguments.count > 1 && !arguments[1].hasPrefix("-")
        ? arguments[1]
        : environment["DARKBLOOM_GUEST_AGENT_PORT"]
    guard let raw else {
        return AgentDefaults.port
    }
    guard let port = UInt32(raw), port > 0 else {
        fail("invalid port \(raw)", code: 64)
    }
    return port
}

private func writeAll(_ descriptor: Int32, _ bytes: Data) -> Bool {
    var offset = 0
    return bytes.withUnsafeBytes { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        while offset < buffer.count {
            let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
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

private func send(_ frame: SandboxGuestFrame, to descriptor: Int32) -> Bool {
    guard let encoded = try? SandboxGuestFrameCodec.encode(frame) else {
        return false
    }
    return writeAll(descriptor, encoded)
}

private func failureFrame(code: String, message: String) -> SandboxGuestFrame? {
    guard let payload = try? JSONEncoder().encode(
        SandboxGuestFailure(code: code, message: message)
    ) else {
        return nil
    }
    return SandboxGuestFrame(kind: .failure, payload: payload)
}

private func listeningSocket(port: UInt32) -> Int32 {
    let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
    guard listener >= 0 else {
        fail("cannot create AF_VSOCK socket (errno \(errno)); this must run inside a VM")
    }

    var address = sockaddr_vm()
    address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
    address.svm_family = sa_family_t(AF_VSOCK)
    address.svm_port = port
    address.svm_cid = VMADDR_CID_ANY

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            bind(listener, rebound, socklen_t(MemoryLayout<sockaddr_vm>.size))
        }
    }
    guard bound == 0 else {
        close(listener)
        fail("cannot bind vsock port \(port) (errno \(errno))")
    }
    guard listen(listener, AgentDefaults.backlog) == 0 else {
        close(listener)
        fail("cannot listen on vsock port \(port) (errno \(errno))")
    }
    return listener
}

/// Announces identity, then answers framed requests until the peer closes.
private func serve(connection: Int32) {
    defer { close(connection) }

    let handshake = SandboxGuestHandshake(
        agentVersion: AgentDefaults.agentVersion,
        imageID: ProcessInfo.processInfo.environment["DARKBLOOM_GUEST_IMAGE_ID"] ?? ""
    )
    guard let handshakePayload = try? JSONEncoder().encode(handshake),
          send(
              SandboxGuestFrame(kind: .handshake, payload: handshakePayload),
              to: connection
          )
    else {
        log("handshake write failed (errno \(errno))")
        return
    }

    var inbound = Data()
    var chunk = [UInt8](repeating: 0, count: AgentDefaults.readChunkBytes)

    while true {
        let received = chunk.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            while true {
                let result = read(connection, base, raw.count)
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

        // A peer that never completes a frame must not grow the buffer without
        // bound; the codec's own cap only applies once a header is present.
        guard inbound.count <= AgentDefaults.maximumInboundBuffer else {
            log("inbound buffer exceeded the frame limit")
            return
        }

        while true {
            let frame: SandboxGuestFrame?
            do {
                frame = try SandboxGuestFrameCodec.decode(from: &inbound)
            } catch {
                log("refusing malformed frame: \(error)")
                if let failure = failureFrame(
                    code: "malformed_frame",
                    message: "\(error)"
                ) {
                    _ = send(failure, to: connection)
                }
                return
            }
            guard let frame else { break }
            if !handle(frame: frame, on: connection) {
                return
            }
        }
    }
}

/// Returns false when the connection should be closed.
private func handle(frame: SandboxGuestFrame, on connection: Int32) -> Bool {
    switch frame.kind {
    case .commandRequest:
        guard let wire = try? JSONDecoder().decode(
            SandboxGuestCommandWire.self,
            from: frame.payload
        ) else {
            _ = failureFrame(
                code: "malformed_request",
                message: "command request could not be decoded"
            ).map { send($0, to: connection) }
            return true
        }
        guard wire.isWellFormed else {
            _ = failureFrame(
                code: "invalid_request",
                message: "command request failed guest-side validation"
            ).map { send($0, to: connection) }
            return true
        }
        // Deliberately not executed. See the note at the top of this file.
        log("refusing command \(wire.idempotencyKey): execution is not enabled")
        _ = failureFrame(
            code: "execution_disabled",
            message: "guest execution is not enabled until randomized bootstrap "
                + "credentials and an unprivileged sandbox user are in place"
        ).map { send($0, to: connection) }
        return true

    case .handshake, .commandResult, .failure:
        // These are agent-to-host kinds. Receiving one means the peer is not a
        // Darkbloom broker, so fail closed rather than guessing.
        log("refusing host-inbound frame of kind \(frame.kind)")
        _ = failureFrame(
            code: "unexpected_frame",
            message: "frame kind \(frame.kind) is not valid from the host"
        ).map { send($0, to: connection) }
        return false
    }
}

let port = resolvePort()
let listener = listeningSocket(port: port)
log("listening on vsock port \(port)")

// SIGPIPE would kill the agent when a broker disconnects mid-write; writeAll
// reports the error instead.
signal(SIGPIPE, SIG_IGN)

while true {
    let connection = accept(listener, nil, nil)
    if connection < 0 {
        if errno == EINTR { continue }
        close(listener)
        fail("accept failed (errno \(errno))")
    }
    log("accepted a broker connection")
    serve(connection: connection)
}
