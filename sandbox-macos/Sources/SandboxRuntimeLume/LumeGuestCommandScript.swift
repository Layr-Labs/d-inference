import Foundation
import SandboxRuntime

enum LumeGuestCommandScript {
    static func execution(
        _ request: SandboxGuestCommandRequest
    ) throws -> String {
        let identifier = LumeGuestCommandIdentity.identifier(
            for: request.idempotencyKey
        )
        let jobLabel = LumeGuestCommandIdentity.jobLabel(
            for: request.idempotencyKey
        )
        let propertyList = try LumeGuestLaunchDefinition.propertyList(
            for: request,
            jobLabel: jobLabel
        ).base64EncodedString()
        let captureBlockBytes = 1_024
        let captureBlockCount =
            LumeGuestCommandEnvelope.maximumStreamBytes / captureBlockBytes
        precondition(
            captureBlockBytes * captureBlockCount
                == LumeGuestCommandEnvelope.maximumStreamBytes
        )
        return """
            #!/bin/zsh
            set -u
            umask 077
            [[ -d \(shellQuote(request.workingDirectory)) \
            && -x \(shellQuote(request.executable)) ]] || exit 70
            control_root="${HOME:-/Users/lume}/Library/Caches/dev.darkbloom.sandbox/commands"
            if [[ -e "$control_root" \
            && ( ! -d "$control_root" || -L "$control_root" ) ]]; then
              exit 70
            fi
            /bin/mkdir -p "$control_root" || exit 70
            [[ "$(/usr/bin/stat -f '%u' "$control_root")" \
            == "$(/usr/bin/id -u)" ]] || exit 70
            /bin/chmod 0700 "$control_root" || exit 70
            cancel_file="$control_root/\(identifier).cancelled"
            command_lock="$control_root/\(identifier).lock"
            [[ ! -e "$cancel_file" ]] || exit 125
            job_label="\(jobLabel)"
            launch_domain="gui/$(/usr/bin/id -u)"
            if /bin/launchctl print "$launch_domain/$job_label" \
            >/dev/null 2>&1; then
              exit 70
            fi

            capture_root=$(/usr/bin/mktemp -d \
            "${TMPDIR:-/tmp}/darkbloom-guest.XXXXXXXX") || exit 70
            stdout_fifo="$capture_root/stdout.fifo"
            stderr_fifo="$capture_root/stderr.fifo"
            stdout_file="$capture_root/stdout"
            stderr_file="$capture_root/stderr"
            stdout_overflow="$capture_root/stdout.overflow"
            stderr_overflow="$capture_root/stderr.overflow"
            envelope_file="$capture_root/envelope"
            status_file="$capture_root/command.status"
            timed_out_file="$capture_root/command.timed-out"
            job_plist="$capture_root/command.plist"
            stdout_capture_pid=""
            stderr_capture_pid=""
            job_loaded=false

            cleanup() {
              if [[ "$job_loaded" == true ]]; then
                /bin/launchctl bootout "$launch_domain/$job_label" \
                >/dev/null 2>&1 || true
              fi
              exec 7>&- 2>/dev/null || true
              exec 8>&- 2>/dev/null || true
              [[ -z "$stdout_capture_pid" ]] \
              || /bin/kill -TERM "$stdout_capture_pid" 2>/dev/null || true
              [[ -z "$stderr_capture_pid" ]] \
              || /bin/kill -TERM "$stderr_capture_pid" 2>/dev/null || true
              /bin/rm -rf -- "$capture_root"
            }
            trap cleanup EXIT
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM

            /usr/bin/mkfifo "$stdout_fifo" "$stderr_fifo" || exit 70
            exec 7<>"$stdout_fifo" || exit 70
            exec 8<>"$stderr_fifo" || exit 70

            capture_stream() {
              local fifo="$1"
              local output="$2"
              local overflow="$3"
              local capture_status=0
              /bin/dd bs=\(captureBlockBytes) count=\(captureBlockCount) \
            iflag=fullblock of="$output" 2>/dev/null
              [[ "$?" -eq 0 ]] || capture_status=1
              /bin/dd bs=1 count=1 iflag=fullblock \
            of="$overflow" 2>/dev/null
              [[ "$?" -eq 0 ]] || capture_status=1
              /bin/cat >/dev/null
              [[ "$?" -eq 0 ]] || capture_status=1
              return "$capture_status"
            }

            capture_stream "$stdout_fifo" "$stdout_file" \
            "$stdout_overflow" < "$stdout_fifo" 7>&- 8>&- &
            stdout_capture_pid=$!
            capture_stream "$stderr_fifo" "$stderr_file" \
            "$stderr_overflow" < "$stderr_fifo" 7>&- 8>&- &
            stderr_capture_pid=$!

            /usr/bin/printf '%s' '\(propertyList)' \
            | /usr/bin/base64 -D > "$job_plist" || exit 70
            /usr/bin/plutil -replace StandardOutPath \
            -string "$stdout_fifo" "$job_plist" || exit 70
            /usr/bin/plutil -replace StandardErrorPath \
            -string "$stderr_fifo" "$job_plist" || exit 70
            /usr/bin/plutil -replace \
            EnvironmentVariables.DARKBLOOM_RESULT_DIR \
            -string "$capture_root" "$job_plist" || exit 70

            job_loaded=true
            /usr/bin/lockf -t 30 "$command_lock" /bin/zsh -f -c '
              cancel_file="$1"
              launch_domain="$2"
              job_plist="$3"
              [[ ! -e "$cancel_file" ]] || exit 125
              /bin/launchctl bootstrap "$launch_domain" "$job_plist"
            ' darkbloom-bootstrap "$cancel_file" "$launch_domain" "$job_plist"
            bootstrap_status=$?
            if [[ "$bootstrap_status" -eq 125 ]]; then
              exit 125
            fi
            [[ "$bootstrap_status" -eq 0 ]] || exit 70
            [[ ! -e "$cancel_file" ]] || exit 125

            while [[ ! -f "$status_file" ]]; do
              [[ ! -e "$cancel_file" ]] || exit 125
              job_description=$(/bin/launchctl print \
              "$launch_domain/$job_label" 2>/dev/null) || exit 70
              if [[ "$job_description" == *"active count = 0"* \
              && "$job_description" == *"runs = 1"* ]]; then
                [[ -f "$status_file" ]] || exit 70
              fi
              /bin/sleep 0.05
            done
            IFS= read -r command_status < "$status_file" || exit 70
            case "$command_status" in
              ''|*[!0-9]*) exit 70 ;;
            esac
            [[ "$command_status" -le 255 ]] || exit 70
            if /bin/launchctl print "$launch_domain/$job_label" \
            >/dev/null 2>&1; then
              /bin/launchctl bootout "$launch_domain/$job_label" \
              >/dev/null 2>&1 || true
            fi
            if /bin/launchctl print "$launch_domain/$job_label" \
            >/dev/null 2>&1; then
              exit 70
            fi
            job_loaded=false
            exec 7>&-
            exec 8>&-

            wait "$stdout_capture_pid"
            stdout_capture_status=$?
            stdout_capture_pid=""
            wait "$stderr_capture_pid"
            stderr_capture_status=$?
            stderr_capture_pid=""
            if [[ "$stdout_capture_status" -ne 0 \
            || "$stderr_capture_status" -ne 0 ]]; then
              exit 70
            fi

            stdout_length=$(/usr/bin/stat -f '%z' "$stdout_file") || exit 70
            stderr_length=$(/usr/bin/stat -f '%z' "$stderr_file") || exit 70
            [[ -s "$stdout_overflow" ]] \
            && stdout_truncated=true || stdout_truncated=false
            [[ -s "$stderr_overflow" ]] \
            && stderr_truncated=true || stderr_truncated=false
            [[ -s "$timed_out_file" ]] \
            && timed_out=true || timed_out=false
            builtin printf \
            '{"magic":"\(LumeGuestCommandEnvelope.magic)",'\
            '"schema_version":\(LumeGuestCommandEnvelope.schemaVersion),'\
            '"exit_code":%d,"stdout_length":%d,"stderr_length":%d,'\
            '"stdout_truncated":%s,"stderr_truncated":%s,'\
            '"timed_out":%s,'\
            '"stdout_base64":"' \
            "$command_status" "$stdout_length" "$stderr_length" \
            "$stdout_truncated" "$stderr_truncated" "$timed_out" \
            > "$envelope_file" || exit 70
            /usr/bin/base64 < "$stdout_file" \
            | /usr/bin/tr -d '\\n' >> "$envelope_file" || exit 70
            builtin printf '","stderr_base64":"' \
            >> "$envelope_file" || exit 70
            /usr/bin/base64 < "$stderr_file" \
            | /usr/bin/tr -d '\\n' >> "$envelope_file" || exit 70
            builtin printf '"}\\n' >> "$envelope_file" || exit 70
            /bin/cat "$envelope_file" || exit 70
            """
    }

    static func cancellation(_ idempotencyKey: UUID) -> String {
        let identifier = LumeGuestCommandIdentity.identifier(
            for: idempotencyKey
        )
        return """
            #!/bin/zsh
            set -u
            umask 077
            control_root="${HOME:-/Users/lume}/Library/Caches/dev.darkbloom.sandbox/commands"
            if [[ -e "$control_root" \
            && ( ! -d "$control_root" || -L "$control_root" ) ]]; then
              exit 70
            fi
            /bin/mkdir -p "$control_root" || exit 70
            [[ "$(/usr/bin/stat -f '%u' "$control_root")" \
            == "$(/usr/bin/id -u)" ]] || exit 70
            /bin/chmod 0700 "$control_root" || exit 70
            cancellation="$control_root/\(identifier).cancelled"
            command_lock="$control_root/\(identifier).lock"
            launch_domain="gui/$(/usr/bin/id -u)"
            job_label="\(LumeGuestCommandIdentity.jobLabel(for: idempotencyKey))"
            /usr/bin/lockf -t 30 "$command_lock" /bin/zsh -f -c '
              cancellation="$1"
              identifier="$2"
              launch_domain="$3"
              job_label="$4"
              temporary="${cancellation}.partial.$$"
              /usr/bin/printf "%s\\n" "$identifier" \
              > "$temporary" || exit 70
              /bin/chmod 0600 "$temporary" || exit 70
              /bin/mv -f "$temporary" "$cancellation" || exit 70
              /bin/launchctl bootout "$launch_domain/$job_label" \
              >/dev/null 2>&1 || true
              if /bin/launchctl print "$launch_domain/$job_label" \
              >/dev/null 2>&1; then
                exit 70
              fi
            ' darkbloom-cancel "$cancellation" '\(identifier)' \
            "$launch_domain" "$job_label" || exit 70
            """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
