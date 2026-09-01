import Darwin
import Foundation

// Minimal guest-side agent proving the vsock transport end to end.
//
// It binds AF_VSOCK inside the guest, announces itself, and echoes whatever it
// is sent. It deliberately does NOT execute anything: this milestone proves a
// byte channel exists, and execution stays gated until the signed
// guest-control agent replaces Lume's shared bootstrap identity.
//
// AF_VSOCK sockets can only be created inside a virtual machine. On a host
// this exits immediately with ENODEV, which is the documented behaviour and a
// useful smoke check.

private enum AgentDefaults {
    static let port: UInt32 = 8_888
    static let protocolVersion = 1
    static let agentVersion = "0.1.0"
    static let magic = "darkbloom_guest_agent"
    static let backlog: Int32 = 4
    static let readBufferBytes = 64 * 1024
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
    let raw = arguments.count > 1
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

/// Identity the host verifies during the readiness handshake. Sourced from the
/// environment so the base image can stamp it without recompiling the agent.
private func handshakeLine(port: UInt32) -> Data {
    let environment = ProcessInfo.processInfo.environment
    let fields: [(String, String)] = [
        ("magic", AgentDefaults.magic),
        ("protocol_version", String(AgentDefaults.protocolVersion)),
        ("agent_version", AgentDefaults.agentVersion),
        ("image_id", environment["DARKBLOOM_GUEST_IMAGE_ID"] ?? ""),
        ("port", String(port)),
    ]
    let body = fields
        .map { "\"\($0.0)\":\"\($0.1)\"" }
        .joined(separator: ",")
    return Data("{\(body)}\n".utf8)
}

private func writeAll(_ descriptor: Int32, _ bytes: Data) -> Bool {
    var offset = 0
    return bytes.withUnsafeBytes { buffer -> Bool in
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
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) { rebound in
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

/// Announces identity, then echoes until the peer closes.
private func serve(connection: Int32, port: UInt32) {
    defer { close(connection) }

    guard writeAll(connection, handshakeLine(port: port)) else {
        log("handshake write failed (errno \(errno))")
        return
    }

    var buffer = [UInt8](repeating: 0, count: AgentDefaults.readBufferBytes)
    while true {
        let received = buffer.withUnsafeMutableBytes { raw -> Int in
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
        let echoed = buffer.prefix(received)
        guard writeAll(connection, Data(echoed)) else {
            log("echo write failed (errno \(errno))")
            return
        }
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
    serve(connection: connection, port: port)
}
