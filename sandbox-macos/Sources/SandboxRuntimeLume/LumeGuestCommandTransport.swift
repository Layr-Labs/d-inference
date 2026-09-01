import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// How an encoded guest command reaches the guest and how its result comes
/// back.
///
/// Two transports exist. The launchd bootstrap path over `lume ssh` is the
/// default and is unchanged. The vsock path speaks `SandboxGuestProtocol` to
/// the signed guest agent. They are interchangeable because both return the
/// **same raw result envelope bytes**: `LumeGuestCommandJournal` persists those
/// bytes and re-validates them with `LumeGuestCommandResultDecoder`, so the
/// format is a fixed contract and only the delivery differs.
package protocol LumeGuestCommandTransport: Sendable {
    /// Validates and encodes the request.
    ///
    /// Kept separate from delivery on purpose: `execute` claims the command in
    /// the durable journal between the two, and a request that cannot be
    /// encoded must fail *before* that claim rather than leaving an
    /// unresolvable one behind.
    func prepare(
        _ request: SandboxGuestCommandRequest
    ) throws -> LumeGuestPreparedCommand

    /// Delivers a prepared command and returns the raw result envelope.
    func deliver(
        virtualMachineName name: String,
        prepared: LumeGuestPreparedCommand,
        guestTimeoutSeconds: UInt32
    ) async throws -> Data

    /// Describes the transport in errors, so a failure names the thing that
    /// actually failed rather than always saying `lume ssh`.
    var description: String { get }
}

/// A request encoded for one specific transport.
package struct LumeGuestPreparedCommand: Sendable {
    package enum Payload: Sendable {
        /// Base64 zsh script for the launchd bootstrap wrapper.
        case encodedScript(String)
        /// Structured request for the signed guest agent.
        case wire(SandboxGuestCommandWire)
    }

    package let payload: Payload

    package init(payload: Payload) {
        self.payload = payload
    }
}

extension SandboxGuestCommandWire {
    /// Converts a host request into its wire form.
    ///
    /// The host has already enforced every limit in
    /// `SandboxGuestCommandRequest.init`, and the agent re-checks the same
    /// limits on arrival, so this is a pure re-shaping.
    package init(request: SandboxGuestCommandRequest) {
        self.init(
            idempotencyKey: request.idempotencyKey.uuidString.lowercased(),
            executable: request.executable,
            arguments: request.arguments,
            environment: request.environment,
            workingDirectory: request.workingDirectory,
            timeoutSeconds: request.timeoutSeconds
        )
    }
}
