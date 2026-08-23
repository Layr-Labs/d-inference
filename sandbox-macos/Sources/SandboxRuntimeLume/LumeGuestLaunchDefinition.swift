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
        environment["DARKBLOOM_JOB_LABEL"] =
            LumeGuestCommandIdentity.jobLabel(for: request.idempotencyKey)
        environment["DARKBLOOM_RESULT_DIR"] = "/dev/null"
        environment["DARKBLOOM_TIMEOUT_SECONDS"] =
            String(request.timeoutSeconds)

        let statusWrapper = """
            umask 077
            status_path="${DARKBLOOM_RESULT_DIR:?}/command.status"
            completion_path="${DARKBLOOM_RESULT_DIR}/command.completed"
            timeout_path="${DARKBLOOM_RESULT_DIR}/command.timed-out"
            (
              /bin/sleep "${DARKBLOOM_TIMEOUT_SECONDS:?}"
              [[ -e "$completion_path" ]] && exit 0
              timeout_temporary="${timeout_path}.partial.$$"
              status_temporary="${status_path}.partial.$$"
              /usr/bin/printf 'true\\n' > "$timeout_temporary" || exit 70
              /bin/mv -f "$timeout_temporary" "$timeout_path" || exit 70
              /usr/bin/printf '124\\n' > "$status_temporary" || exit 70
              /bin/mv -f "$status_temporary" "$status_path" || exit 70
              /bin/launchctl bootout \
              "gui/$(/usr/bin/id -u)/${DARKBLOOM_JOB_LABEL:?}" \
              >/dev/null 2>&1 || true
            ) &
            watchdog_pid=$!

            "$@" < /dev/null &
            command_pid=$!
            wait "$command_pid"
            command_status=$?
            /usr/bin/touch "$completion_path" || exit 70
            /bin/kill -TERM "$watchdog_pid" 2>/dev/null || true
            wait "$watchdog_pid" 2>/dev/null || true
            if [[ ! -e "$status_path" ]]; then
              temporary_status="${status_path}.partial.$$"
              /usr/bin/printf '%d\\n' "$command_status" \
              > "$temporary_status" || exit 70
              /bin/chmod 0600 "$temporary_status" || exit 70
              /bin/mv -f "$temporary_status" "$status_path" || exit 70
            fi
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
