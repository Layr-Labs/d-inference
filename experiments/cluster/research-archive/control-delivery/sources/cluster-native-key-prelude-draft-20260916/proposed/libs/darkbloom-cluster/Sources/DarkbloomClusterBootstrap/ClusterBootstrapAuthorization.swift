import Foundation

/// Opt-in is explicit at BOTH ends. Existing mesh2 framing and rounds retain
/// their original bytes; a protected connection cannot start mesh prematurely.
public enum ClusterBootstrapMode: Sendable {
    case mesh2, nativeKeyPreludeV1
}

/// All fields are public metadata. No private/shared/traffic key belongs here.
/// Opaque construction requires the actual native-side owned socket exchange.
public final class ClusterNativePreludeContext: @unchecked Sendable {
    private let connection: ClusterBootstrapConnection
    private let claimLock = NSLock()
    private var claimed = false, cancelled = false
    private var cancellation: (@Sendable () -> Void)?
    public let startBytes: Data
    public var identity: ClusterBootstrapIdentity { connection.identity }
    public var deadlineUptimeNanoseconds: UInt64 { connection.deadlineUptimeNanoseconds }
    init(connection: ClusterBootstrapConnection, start: Data) {
        self.connection = connection; startBytes = start
    }
    /// Single holder, no reset. A second attempted claim poisons this socket.
    public func claimNativeKeyHolder(onCancellation: @escaping @Sendable () -> Void) throws {
        do {
            try claimLock.withLock {
                guard !claimed, !cancelled else { throw ClusterBootstrapError.invalid("Native key context already claimed or cancelled") }
                claimed = true; cancellation = onCancellation
            }
            try connection.checkKeyPrelude()
        } catch { cancel(); throw error }
    }
    public func requireLive() throws { try connection.checkKeyPrelude() }
    public func exchangeHello(_ publicHello: Data) throws -> Data {
        try connection.nativeKeyExchange(publicHello, confirmation: false)
    }
    public func exchangeConfirmation(_ tag: Data) throws -> Data {
        try connection.nativeKeyExchange(tag, confirmation: true)
    }
    public func complete(transcriptSHA256: Data) throws {
        try connection.nativeKeyComplete(transcriptSHA256)
    }
    public func cancel() {
        let callback = claimLock.withLock {
            cancelled = true
            let value = cancellation; cancellation = nil
            return value
        }
        connection.cancel()
        callback?() // Never under the context lock; recursive cancellation is inert.
    }
}

/// Public-record relay only, never native approval or a cleanup receipt.
public final class ClusterOwnerPreludeContext: @unchecked Sendable {
    private let connection: ClusterBootstrapConnection
    init(connection: ClusterBootstrapConnection) { self.connection = connection }
    public func receiveHello() throws -> Data { try connection.ownerKeyRead(confirmation: false) }
    public func sendBinding(_ bytes: Data) throws { try connection.ownerKeyWrite(bytes, confirmation: false) }
    public func receiveConfirmation() throws -> Data { try connection.ownerKeyRead(confirmation: true) }
    public func sendPeerConfirmation(_ tag: Data) throws { try connection.ownerKeyWrite(tag, confirmation: true) }
    public func requireComplete(transcriptSHA256: Data) throws { try connection.ownerKeyComplete(transcriptSHA256) }
    public func cancel() { connection.cancel() }
}

/// Mutated only inside ClusterBootstrapConnection.operation. A socket error,
/// concurrent entry or cancellation poisons the owning connection permanently.
final class BootstrapAuthorization {
    private enum Phase: Equatable {
        case mesh, nativeStart, nativeHello, nativeConfirmation, nativeComplete
        case ownerStart, ownerHello, ownerBinding, ownerConfirmation, ownerPeerConfirmation, ownerComplete
    }
    private var phase: Phase
    init(worker: Bool, mode: ClusterBootstrapMode) {
        switch mode {
        case .mesh2: phase = .mesh
        case .nativeKeyPreludeV1: phase = worker ? .nativeStart : .ownerStart
        }
    }
    func requireMesh() throws {
        guard phase == .mesh else { throw ClusterBootstrapError.invalid("Native authorization is incomplete") }
    }
    func nativeStart(_ expected: Data, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws {
        guard phase == .nativeStart else { throw ClusterBootstrapError.invalid("Unexpected native authorization start") }
        guard (1...PreludePacket.maximumBytes).contains(expected.count) else { throw ClusterBootstrapError.invalid("Native expected start size differs") }
        let observed = try PreludePacket.read(.start, socket: socket, identity: identity)
        guard expected == observed else { throw ClusterBootstrapError.invalid("Local native start binding differs") }
        phase = .nativeHello
    }
    func ownerStart(_ start: Data, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws {
        guard phase == .ownerStart else { throw ClusterBootstrapError.invalid("Unexpected owner authorization start") }
        try PreludePacket.write(start, kind: .start, socket: socket, identity: identity)
        phase = .ownerHello
    }
    func nativeExchange(_ bytes: Data, confirmation: Bool, socket: BootstrapSocket,
                        identity: ClusterBootstrapIdentity) throws -> Data {
        guard phase == (confirmation ? .nativeConfirmation : .nativeHello) else {
            throw ClusterBootstrapError.invalid("Unexpected native authorization exchange")
        }
        try PreludePacket.write(bytes, kind: confirmation ? .confirmation : .hello, socket: socket, identity: identity)
        let result = try PreludePacket.read(confirmation ? .peerConfirmation : .binding, socket: socket, identity: identity)
        phase = confirmation ? .nativeComplete : .nativeConfirmation
        return result
    }
    func nativeComplete(_ digest: Data, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws {
        guard phase == .nativeComplete else { throw ClusterBootstrapError.invalid("Unexpected native authorization completion") }
        try PreludePacket.write(digest, kind: .complete, socket: socket, identity: identity)
        phase = .mesh
    }
    func ownerRead(confirmation: Bool, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws -> Data {
        guard phase == (confirmation ? .ownerConfirmation : .ownerHello) else {
            throw ClusterBootstrapError.invalid("Unexpected owner authorization read")
        }
        let result = try PreludePacket.read(confirmation ? .confirmation : .hello, socket: socket, identity: identity)
        phase = confirmation ? .ownerPeerConfirmation : .ownerBinding
        return result
    }
    func ownerWrite(_ bytes: Data, confirmation: Bool, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws {
        guard phase == (confirmation ? .ownerPeerConfirmation : .ownerBinding) else {
            throw ClusterBootstrapError.invalid("Unexpected owner authorization write")
        }
        try PreludePacket.write(bytes, kind: confirmation ? .peerConfirmation : .binding, socket: socket, identity: identity)
        phase = confirmation ? .ownerComplete : .ownerConfirmation
    }
    func ownerComplete(_ digest: Data, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws {
        guard phase == .ownerComplete else { throw ClusterBootstrapError.invalid("Unexpected owner authorization completion") }
        let observed = try PreludePacket.read(.complete, socket: socket, identity: identity)
        guard observed == digest else { throw ClusterBootstrapError.invalid("Native authorization transcript differs") }
        phase = .mesh
    }
}
