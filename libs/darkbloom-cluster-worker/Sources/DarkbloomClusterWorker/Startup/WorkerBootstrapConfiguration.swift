import DarkbloomClusterBootstrap
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity
import Foundation

/// The owner's bootstrap attachment (PROD-PLAN S07): a PID-authenticated
/// local socket to the owner that launched this worker, through which JACCL's
/// side channel is relayed by both authenticated owners. With a native start,
/// the native key prelude runs first on the same connection: the two workers
/// agree an X25519 key bound to the committed start, then the mesh rounds
/// follow.
struct WorkerBootstrapConfiguration {
    static let names: Set<String> = ["--bootstrap-socket-path", "--bootstrap-owner-pid",
        "--bootstrap-deadline-uptime-nanoseconds"]
    static let nativeStartName = "--native-authorization-start-base64"
    static var allNames: Set<String> { names.union([nativeStartName]) }
    let path: String
    let ownerProcessID: Int32
    let deadlineUptimeNanoseconds: UInt64
    /// The committed native start, exactly as the owner was given it.
    let nativeStart: Data?

    /// `lifetime` bounds how far away the bootstrap deadline may be. A worker
    /// has no fixed lifetime; its rank lease is renewed during the bootstrap.
    static func parse(_ fields: [String: String], now: UInt64, lifetime: UInt64) throws -> Self? {
        let supplied = names.filter { fields[$0] != nil }
        if supplied.isEmpty {
            guard fields[nativeStartName] == nil else { throw WorkerFailure.invalid("A native start requires the bootstrap attachment") }
            return nil // Direct native bootstrap: JACCL opens its own coordinator socket.
        }
        guard supplied.count == names.count, let path = fields["--bootstrap-socket-path"],
              path.hasPrefix("/"), path.utf8.count < 104, !path.contains("\0"),
              let pidText = fields["--bootstrap-owner-pid"], let pid = Int32(pidText),
              pid > 1, String(pid) == pidText,
              let deadlineText = fields["--bootstrap-deadline-uptime-nanoseconds"],
              let deadline = UInt64(deadlineText), String(deadline) == deadlineText,
              deadline > now, deadline - now <= lifetime else {
            throw WorkerFailure.invalid("Bootstrap requires the complete bounded local attachment")
        }
        var start: Data?
        if let text = fields[nativeStartName] {
            guard let bytes = Data(base64Encoded: text), (1...3072).contains(bytes.count),
                  bytes.base64EncodedString() == text, (try? ClusterNativeAuthorizationStart(encoded: bytes)) != nil else {
                throw WorkerFailure.invalid("Native authorization start must be one canonical encoded start")
            }
            start = bytes
        }
        return .init(path: path, ownerProcessID: pid, deadlineUptimeNanoseconds: deadline, nativeStart: start)
    }

    func connect(epoch: UUID, rank: Int) throws -> ClusterBootstrapConnection {
        try .connect(path: path, ownerProcessID: ownerProcessID,
            identity: .init(membershipEpoch: epoch, rank: rank),
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            mode: nativeStart == nil ? .mesh2 : .nativeKeyPreludeV1)
    }

    /// Connects to the owner, runs the native key prelude when a start was
    /// given, and installs the mesh exchange for this process's JACCL group.
    /// The returned attachment must live as long as the worker: it holds the
    /// connection and the confirmed native key authority.
    func attach(epoch: UUID, rank: Int) throws -> WorkerOwnerAttachment {
        let connection = try connect(epoch: epoch, rank: rank)
        do {
            var authority: ClusterNativeRecordAuthority?
            if let nativeStart {
                let start = try ClusterNativeAuthorizationStart(encoded: nativeStart)
                guard start.common.epoch == epoch, start.rank == rank else {
                    throw WorkerFailure.invalid("Native authorization start names another epoch or rank")
                }
                let value = try ClusterNativeRecordAuthority(ownedPrelude: connection.beginNativeKeyPrelude(expecting: nativeStart))
                _ = try value.establish()
                authority = value
            }
            try JACCLOwnerBootstrap.install(rank: rank) { sequence, contribution in
                try connection.exchange(sequence: sequence, contribution: contribution)
            }
            return .init(connection: connection, authority: authority)
        } catch { connection.cancel(); throw error }
    }
}

/// Retained by the runtime for the worker's lifetime.
final class WorkerOwnerAttachment: @unchecked Sendable {
    let connection: ClusterBootstrapConnection
    /// The confirmed native key (the record master for an encrypted data
    /// plane); held, never exported.
    let authority: ClusterNativeRecordAuthority?
    init(connection: ClusterBootstrapConnection, authority: ClusterNativeRecordAuthority?) {
        self.connection = connection; self.authority = authority
    }
}
