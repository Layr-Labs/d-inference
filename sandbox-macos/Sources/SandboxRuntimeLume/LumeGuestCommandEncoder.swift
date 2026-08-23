import Foundation
import SandboxRuntime

enum LumeGuestCommandEncoder {
    static func encode(_ request: SandboxGuestCommandRequest) -> String {
        let encoded = Data(script(request).utf8).base64EncodedString()
        return "/usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -D | /bin/zsh"
    }

    static func script(_ request: SandboxGuestCommandRequest) -> String {
        var environment = request.environment
        environment["DARKBLOOM_IDEMPOTENCY_KEY"] =
            request.idempotencyKey.uuidString.lowercased()

        let environmentAssignments = environment
            .sorted { $0.key < $1.key }
            .map { shellQuote("\($0.key)=\($0.value)") }
            .joined(separator: " ")
        let arguments = ([request.executable] + request.arguments)
            .map(shellQuote)
            .joined(separator: " ")
        let environmentPrefix = environmentAssignments.isEmpty
            ? "/usr/bin/env"
            : "/usr/bin/env \(environmentAssignments)"
        return """
            #!/bin/zsh
            set -e
            builtin cd -- \(shellQuote(request.workingDirectory))
            exec \(environmentPrefix) \(arguments)
            """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
