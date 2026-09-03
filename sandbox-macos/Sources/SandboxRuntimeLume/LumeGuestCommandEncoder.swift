import Foundation
import SandboxRuntime

enum LumeGuestCommandEncoder {
    /// No default `home`: see `script(_:home:)`.
    static func encode(
        _ request: SandboxGuestCommandRequest,
        home: String
    ) throws -> String {
        try encodedShellCommand(
            LumeGuestCommandScript.execution(home: home, request)
        )
    }

    /// Cancellation writes into the same control root the execution script
    /// uses, so it needs the same home. It defaulted to the legacy account
    /// too, which meant a cancellation could never find the job it was meant
    /// to boot out on a per-sandbox guest.
    static func encodeCancellation(
        idempotencyKey: UUID,
        home: String
    ) -> String {
        encodedShellCommand(
            LumeGuestCommandScript.cancellation(idempotencyKey, home: home)
        )
    }

    /// `home` has no default for the same reason `workingDirectory` has none:
    /// it becomes the launchd job's HOME and the control root the script
    /// writes into, and the legacy value it used to default to no longer
    /// exists on a per-sandbox guest.
    static func script(
        _ request: SandboxGuestCommandRequest,
        home: String
    ) throws -> String {
        try LumeGuestCommandScript.execution(home: home, request)
    }

    private static func encodedShellCommand(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "/usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -D | /bin/zsh -f"
    }
}

enum LumeGuestCommandIdentity {
    static func identifier(for idempotencyKey: UUID) -> String {
        idempotencyKey.uuidString.lowercased()
    }

    static func jobLabel(for idempotencyKey: UUID) -> String {
        "dev.darkbloom.sandbox.command.\(identifier(for: idempotencyKey))"
    }
}
