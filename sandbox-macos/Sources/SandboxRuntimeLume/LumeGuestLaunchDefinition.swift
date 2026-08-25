import Foundation
import SandboxRuntime

enum LumeGuestLaunchDefinition {
    private static let deterministicEnvironment = [
        "HOME": "/Users/lume",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/tmp",
    ]

    static func propertyList(
        for request: SandboxGuestCommandRequest,
        jobLabel: String
    ) throws -> Data {
        var controlEnvironment = Self.deterministicEnvironment
        controlEnvironment["DARKBLOOM_IDEMPOTENCY_KEY"] =
            LumeGuestCommandIdentity.identifier(for: request.idempotencyKey)
        controlEnvironment["DARKBLOOM_JOB_LABEL"] =
            LumeGuestCommandIdentity.jobLabel(for: request.idempotencyKey)
        controlEnvironment["DARKBLOOM_RESULT_DIR"] = "/dev/null"
        controlEnvironment["DARKBLOOM_TIMEOUT_SECONDS"] =
            String(request.timeoutSeconds)
        var targetEnvironment = Self.deterministicEnvironment
        targetEnvironment.merge(request.environment) { fixed, _ in fixed }
        targetEnvironment["DARKBLOOM_IDEMPOTENCY_KEY"] =
            LumeGuestCommandIdentity.identifier(for: request.idempotencyKey)
        let targetArguments = ["/usr/bin/env", "-i"]
            + targetEnvironment.sorted(by: { $0.key < $1.key }).map {
                "\($0.key)=\($0.value)"
            }
            + [request.executable]
            + request.arguments

        let statusWrapper = """
            set -u
            umask 077
            status_path="${DARKBLOOM_RESULT_DIR:?}/command.status"
            terminal_path="${DARKBLOOM_RESULT_DIR}/command.terminal"
            timeout_path="${DARKBLOOM_RESULT_DIR}/command.timed-out"
            write_status() {
              local exit_code="$1"
              local temporary="${status_path}.partial.$$"
              /usr/bin/printf '%d\\n' "$exit_code" > "$temporary" || exit 70
              /bin/chmod 0600 "$temporary" || exit 70
              /bin/mv -f "$temporary" "$status_path" || exit 70
            }
            (
              /bin/sleep "${DARKBLOOM_TIMEOUT_SECONDS:?}"
              /bin/mkdir "$terminal_path" 2>/dev/null || exit 0
              timeout_temporary="${timeout_path}.partial.$$"
              /usr/bin/printf 'true\\n' > "$timeout_temporary" || exit 70
              /bin/chmod 0600 "$timeout_temporary" || exit 70
              /bin/mv -f "$timeout_temporary" "$timeout_path" || exit 70
              write_status 124
              /bin/launchctl bootout \
              "gui/$(/usr/bin/id -u)/${DARKBLOOM_JOB_LABEL:?}" \
              >/dev/null 2>&1 || true
            ) &
            watchdog_pid=$!

            "$@" < /dev/null &
            command_pid=$!
            wait "$command_pid"
            command_status=$?
            if /bin/mkdir "$terminal_path" 2>/dev/null; then
              write_status "$command_status"
              /bin/kill -TERM "$watchdog_pid" 2>/dev/null || true
            fi
            wait "$watchdog_pid" 2>/dev/null || true
            exit "$command_status"
            """
        let definition: [String: Any] = [
            "AbandonProcessGroup": false,
            "EnvironmentVariables": controlEnvironment,
            "ExitTimeOut": 5,
            "Label": jobLabel,
            "ProcessType": "Background",
            "ProgramArguments": [
                "/bin/zsh",
                "-f",
                "-c",
                statusWrapper,
                "darkbloom-command",
            ] + targetArguments,
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
