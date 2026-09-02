import Foundation
import SandboxRuntime

enum LumeGuestCommandEncoder {
    static func encode(
        _ request: SandboxGuestCommandRequest,
        home: String = LumeGuestCredential.legacy.bootstrapHome
    ) throws -> String {
        try encodedShellCommand(
            LumeGuestCommandScript.execution(home: home, request)
        )
    }

    static func encodeCancellation(
        idempotencyKey: UUID
    ) -> String {
        encodedShellCommand(
            LumeGuestCommandScript.cancellation(idempotencyKey)
        )
    }

    static func script(
        _ request: SandboxGuestCommandRequest,
        home: String = LumeGuestCredential.legacy.bootstrapHome
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
