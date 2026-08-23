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
            builtin cd -- \(shellQuote(request.workingDirectory)) || exit 70
            capture_root=$(/usr/bin/mktemp -d \
            "${TMPDIR:-/tmp}/darkbloom-guest.XXXXXXXX") || exit 70
            trap '/bin/rm -rf -- "$capture_root"' EXIT
            stdout_fifo="$capture_root/stdout.fifo"
            stderr_fifo="$capture_root/stderr.fifo"
            stdout_file="$capture_root/stdout"
            stderr_file="$capture_root/stderr"
            stdout_overflow="$capture_root/stdout.overflow"
            stderr_overflow="$capture_root/stderr.overflow"
            envelope_file="$capture_root/envelope"
            /usr/bin/mkfifo "$stdout_fifo" "$stderr_fifo" || exit 70

            capture_stream() {
              local fifo="$1"
              local output="$2"
              local overflow="$3"
              {
                /bin/dd bs=\(captureBlockBytes) count=\(captureBlockCount) \
            iflag=fullblock of="$output" 2>/dev/null
                /bin/dd bs=1 count=1 iflag=fullblock \
            of="$overflow" 2>/dev/null
                /bin/cat >/dev/null
              } < "$fifo"
            }

            capture_stream "$stdout_fifo" "$stdout_file" \
            "$stdout_overflow" &
            stdout_capture_pid=$!
            capture_stream "$stderr_fifo" "$stderr_file" \
            "$stderr_overflow" &
            stderr_capture_pid=$!

            \(environmentPrefix) \(arguments) \
            >"$stdout_fifo" 2>"$stderr_fifo"
            command_status=$?
            wait "$stdout_capture_pid"
            stdout_capture_status=$?
            wait "$stderr_capture_pid"
            stderr_capture_status=$?
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
            builtin printf \
            '{"magic":"\(LumeGuestCommandEnvelope.magic)",'\
            '"schema_version":\(LumeGuestCommandEnvelope.schemaVersion),'\
            '"exit_code":%d,"stdout_length":%d,"stderr_length":%d,'\
            '"stdout_truncated":%s,"stderr_truncated":%s,'\
            '"stdout_base64":"' \
            "$command_status" "$stdout_length" "$stderr_length" \
            "$stdout_truncated" "$stderr_truncated" \
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

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
