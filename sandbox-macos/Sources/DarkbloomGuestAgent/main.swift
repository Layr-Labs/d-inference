import Darwin
import Foundation
import SandboxGuestAgentCore

// Guest-side agent for the vsock channel established by Lume patch 0005.
//
// This executable is only the vsock front door: bind, listen, accept. Every
// byte of protocol handling lives in SandboxGuestAgentCore, which knows nothing
// about vsock — that is what lets both halves of the protocol be exercised
// against each other over a socketpair on a host, where AF_VSOCK cannot exist.
//
// AF_VSOCK sockets can only be created inside a virtual machine. On a host this
// exits immediately with ENODEV, which is documented behaviour and a useful
// smoke check.

private enum AgentDefaults {
    static let port: UInt32 = 8_888
    static let agentVersion = "0.1.0"
    static let backlog: Int32 = 4
}

private func fail(_ message: String, code: Int32 = 70) -> Never {
    FileHandle.standardError.write(Data("darkbloom-guest-agent: \(message)\n".utf8))
    exit(code)
}

private let log: @Sendable (String) -> Void = { message in
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

let port = resolvePort()
let listener = listeningSocket(port: port)
log("listening on vsock port \(port)")

// SIGPIPE would kill the agent when a broker disconnects mid-write; the session
// reports the error instead.
signal(SIGPIPE, SIG_IGN)

let session = SandboxGuestAgentSession(
    configuration: .init(
        agentVersion: AgentDefaults.agentVersion,
        imageID: ProcessInfo.processInfo.environment["DARKBLOOM_GUEST_IMAGE_ID"] ?? "",
        executionEnabled: false
    ),
    log: log
)

while true {
    let connection = accept(listener, nil, nil)
    if connection < 0 {
        if errno == EINTR { continue }
        close(listener)
        fail("accept failed (errno \(errno))")
    }
    log("accepted a broker connection")
    session.serve(descriptor: connection)
    close(connection)
}
