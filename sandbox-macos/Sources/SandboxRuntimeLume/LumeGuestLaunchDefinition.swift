import Foundation
import SandboxRuntime

enum LumeGuestLaunchDefinition {
    static func propertyList(
        for request: SandboxGuestCommandRequest,
        jobLabel: String
    ) throws -> Data {
        var environment: [String: String] = [
            "HOME": "/Users/lume",
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/tmp",
        ]
        environment.merge(request.environment) { _, requested in requested }
        environment["DARKBLOOM_IDEMPOTENCY_KEY"] =
            LumeGuestCommandIdentity.identifier(for: request.idempotencyKey)
        environment["DARKBLOOM_RESULT_DIR"] = "/dev/null"

        let statusWrapper = """
            "$@" < /dev/null
            command_status=$?
            status_path="${DARKBLOOM_RESULT_DIR:?}/command.status"
            temporary_status="${status_path}.partial.$$"
            /usr/bin/printf '%d\\n' "$command_status" \
            > "$temporary_status" || exit 70
            /bin/chmod 0600 "$temporary_status" || exit 70
            /bin/mv -f "$temporary_status" "$status_path" || exit 70
            exit "$command_status"
            """
        let definition: [String: Any] = [
            "AbandonProcessGroup": false,
            "EnvironmentVariables": environment,
            "ExitTimeOut": 5,
            "Label": jobLabel,
            "ProcessType": "Background",
            "ProgramArguments": [
                "/bin/zsh",
                "-c",
                statusWrapper,
                "darkbloom-command",
                request.executable,
            ] + request.arguments,
            "RunAtLoad": true,
            "StandardErrorPath": "/dev/null",
            "StandardInPath": "/dev/null",
            "StandardOutPath": "/dev/null",
            "WorkingDirectory": request.workingDirectory,
        ]
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: definition,
                format: .xml,
                options: 0
            )
        } catch {
            throw SandboxRuntimeError.unsupported(
                "guest command launch definition cannot be encoded"
            )
        }
    }
}
