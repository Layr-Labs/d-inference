import ProviderCoreFoundation

enum FreshInstallFakeCLI {
    // POSIX sh only: no network tools, profiles, launchctl, open, security, or
    // interactive input. `$0` anchors all paths below the temporary harness.
    static func script(processIdentity: ProcessIdentity) -> String {
        return #"""
        #!/bin/sh
        set -eu

        root=${0%/*}
        root=$(CDPATH= cd -- "$root" && pwd)
        control="$root/control"
        machine="$root/machine"
        state_file="$root/state/daemon-state.json"
        local_dir="$root/local"
        argv_file="$root/argv.log"

        # Even if a runner later starts inheriting more of its parent process,
        # the fake's own filesystem defaults remain trapped under the fixture.
        export HOME="$root/home"
        export CFFIXED_USER_HOME="$root/home"
        export XDG_CONFIG_HOME="$root/config"
        export DARKBLOOM_CONFIG="$root/config/provider.toml"
        export DARKBLOOM_STATE_FILE="$state_file"
        export DARKBLOOM_LOCAL_DIR="$local_dir"
        export DARKBLOOM_NO_UPDATE_CHECK=1

        first=1
        for argument in "$@"; do
          if [ "$first" -eq 0 ]; then printf '\034' >> "$argv_file"; fi
          printf '%s' "$argument" >> "$argv_file"
          first=0
        done
        printf '\n' >> "$argv_file"

        mode() {
          mode_value=$2
          if [ -f "$control/$1" ]; then
            IFS= read -r mode_value < "$control/$1" || true
          fi
          printf '%s' "$mode_value"
        }

        emit_doctor() {
          doctor_mode=$(mode doctor ready)
          account_status=warn
          account_detail="not linked"
          if [ -f "$machine/account-linked" ]; then
            account_status=pass
            account_detail="logged in"
          fi
          profile_status=warn
          profile_detail="not installed"
          if [ -f "$machine/profile-installed" ]; then
            profile_status=pass
            profile_detail="yes (darkbloom)"
          fi

          case "$doctor_mode" in
            unsupported)
              hardware_status=fail
              hardware_detail="Intel processors are not supported; Apple silicon is required."
              connectivity_status=pass
              ;;
            low-memory)
              hardware_status=fail
              hardware_detail="Apple M1, 8 GB RAM; at least 16 GB is required."
              connectivity_status=pass
              ;;
            offline)
              hardware_status=pass
              hardware_detail="Apple M4 Pro, 32 GB RAM, 20 GPU cores"
              connectivity_status=fail
              ;;
            conflicting-mdm)
              hardware_status=pass
              hardware_detail="Apple M4 Pro, 32 GB RAM, 20 GPU cores"
              connectivity_status=pass
              profile_status=fail
              profile_detail="another MDM enrollment is installed"
              ;;
            profile-missing)
              hardware_status=pass
              hardware_detail="Apple M4 Pro, 32 GB RAM, 20 GPU cores"
              connectivity_status=pass
              profile_status=fail
              profile_detail="Darkbloom profile is not installed"
              ;;
            *)
              hardware_status=pass
              hardware_detail="Apple M4 Pro, 32 GB RAM, 20 GPU cores"
              connectivity_status=pass
              ;;
          esac

          failures=0
          [ "$hardware_status" != fail ] || failures=$((failures + 1))
          [ "$connectivity_status" != fail ] || failures=$((failures + 1))
          [ "$profile_status" != fail ] || failures=$((failures + 1))
          warnings=0
          [ "$account_status" != warn ] || warnings=$((warnings + 1))
          [ "$profile_status" != warn ] || warnings=$((warnings + 1))
          verdict=pass
          [ "$warnings" -eq 0 ] || verdict=warn
          [ "$failures" -eq 0 ] || verdict=fail

          printf '%s\n' "{\"schema\":1,\"version\":\"0.0.0-fresh-install-test\",\"checks\":[{\"id\":\"hardware\",\"section\":\"hardware\",\"title\":\"hardware\",\"status\":\"$hardware_status\",\"detail\":\"$hardware_detail\"},{\"id\":\"metal-gpu\",\"section\":\"hardware\",\"title\":\"metal gpu\",\"status\":\"pass\",\"detail\":\"available\"},{\"id\":\"macos\",\"section\":\"hardware\",\"title\":\"macOS\",\"status\":\"pass\",\"detail\":\"macOS 15.0\"},{\"id\":\"attestationKey.se-key-sign-test\",\"section\":\"attestationKey\",\"title\":\"SE key sign test\",\"status\":\"pass\",\"detail\":\"sign and verify succeeded\"},{\"id\":\"sip\",\"section\":\"security\",\"title\":\"sip\",\"status\":\"pass\",\"detail\":\"enabled\"},{\"id\":\"authenticated-root\",\"section\":\"security\",\"title\":\"authenticated root\",\"status\":\"pass\",\"detail\":\"enabled\"},{\"id\":\"memory\",\"section\":\"hardware\",\"title\":\"memory\",\"status\":\"$hardware_status\",\"detail\":\"$hardware_detail\"},{\"id\":\"connectivity.coordinator\",\"section\":\"connectivity\",\"title\":\"coordinator\",\"status\":\"$connectivity_status\",\"detail\":\"$([ "$connectivity_status" = pass ] && printf reachable || printf offline)\",\"advice\":\"Check the network and try again.\"},{\"id\":\"account-link\",\"section\":\"attestationReadiness\",\"title\":\"account link\",\"status\":\"$account_status\",\"detail\":\"$account_detail\"},{\"id\":\"attestationReadiness.console-session\",\"section\":\"attestationReadiness\",\"title\":\"console session\",\"status\":\"$account_status\",\"detail\":\"$account_detail\"},{\"id\":\"mdm-enrollment\",\"section\":\"trust\",\"title\":\"mdm enrollment\",\"status\":\"$profile_status\",\"detail\":\"$profile_detail\",\"advice\":\"Run darkbloom enroll and install the profile in System Settings.\"}],\"verdict\":{\"status\":\"$verdict\",\"failures\":$failures,\"warnings\":$warnings}}"
          [ "$failures" -eq 0 ] || exit 1
          exit 0
        }

        if [ "$#" -eq 2 ] && [ "$1" = doctor ] && [ "$2" = --json ]; then
          emit_doctor
        fi

        if [ "$#" -eq 2 ] && [ "$1" = login ] && [ "$2" = --json ]; then
          login_mode=$(mode login linked)
          printf '%s\n' '{"event":"code","user_code":"FRESH-001","verification_uri":"https://app.darkbloom.test/link","expires_in":900}'
          /bin/sleep 0.02
          case "$login_mode" in
            linked)
              : > "$machine/account-linked"
              printf '%s\n' '{"event":"linked"}'
              /bin/sleep 0.02
              exit 0
              ;;
            expired)
              printf '%s\n' '{"event":"error","message":"Device code expired. Request a new code and try again."}'
              /bin/sleep 0.02
              exit 1
              ;;
            denied)
              printf '%s\n' '{"event":"error","message":"Authorization denied. Approve this Mac in the browser, then retry."}'
              /bin/sleep 0.02
              exit 1
              ;;
            *)
              echo "unsupported fake login mode: $login_mode" >&2
              exit 65
              ;;
          esac
        fi

        if [ "$#" -eq 2 ] && [ "$1" = enroll ] && [ "$2" = --json ]; then
          enroll_mode=$(mode enroll opened)
          case "$enroll_mode" in
            opened)
              : > "$machine/profile-requested"
              printf '%s\n' "{\"profile_path\":\"$root/Darkbloom.mobileconfig\",\"schema\":1,\"serial_number\":\"FRESHINSTALL\",\"status\":\"profile_opened\"}"
              exit 0
              ;;
            already-enrolled)
              : > "$machine/profile-installed"
              printf '%s\n' '{"schema":1,"serial_number":"FRESHINSTALL","status":"already_enrolled"}'
              exit 0
              ;;
            failure)
              echo "Could not download the verification profile. Check the network and retry." >&2
              exit 1
              ;;
            *)
              echo "unsupported fake enroll mode: $enroll_mode" >&2
              exit 65
              ;;
          esac
        fi

        if [ "$#" -eq 3 ] && [ "$1" = models ] && [ "$2" = catalog ] && [ "$3" = --json ]; then
          printf '%s\n' '[{"id":"mlx-community/Qwen3.5-0.8B-MLX-4bit","s3_name":"mlx-community__Qwen3.5-0.8B-MLX-4bit/test","display_name":"Qwen 3.5 0.8B","model_type":"text","size_gb":0.5,"description":"Fresh-install fixture","min_ram_gb":16,"family":"Qwen","quantization":"4-bit","max_context_length":32768,"capabilities":["text-generation"],"total_size_bytes":1048576}]'
          exit 0
        fi

        if [ "$#" -eq 3 ] && [ "$1" = models ] && [ "$2" = list ] && [ "$3" = --json ]; then
          if [ -f "$machine/model-downloaded" ]; then
            printf '%s\n' '{"cacheDirectory":"/fresh-install/cache","filteredByConfig":false,"models":[{"id":"mlx-community/Qwen3.5-0.8B-MLX-4bit","model_type":"text","quantization":"4-bit","size_bytes":1048576,"estimated_memory_gb":0.5}]}'
          else
            printf '%s\n' '{"cacheDirectory":"/fresh-install/cache","filteredByConfig":false,"models":[]}'
          fi
          exit 0
        fi

        if [ "$#" -eq 4 ] && [ "$1" = models ] && [ "$2" = download ] && [ "$3" = "mlx-community/Qwen3.5-0.8B-MLX-4bit" ] && [ "$4" = --json ]; then
          download_mode=$(mode download success)
          attempt=0
          if [ -f "$machine/download-attempts" ]; then
            IFS= read -r attempt < "$machine/download-attempts" || true
          fi
          attempt=$((attempt + 1))
          printf '%s\n' "$attempt" > "$machine/download-attempts"

          if [ "$download_mode" = interrupt-once ] && [ "$attempt" -eq 1 ]; then
            : > "$machine/download-partial"
            printf '%s\n' '{"bytes":524288,"event":"progress","file":"model.safetensors","model":"mlx-community/Qwen3.5-0.8B-MLX-4bit","total":1048576}'
            printf '%s\n' '{"event":"error","message":"Download interrupted at 524288 bytes. Retry to resume."}'
            exit 1
          fi
          if [ "$download_mode" = failure ]; then
            printf '%s\n' '{"event":"error","message":"Model download failed. Check disk space and retry."}'
            exit 1
          fi

          if [ -f "$machine/download-partial" ]; then
            printf '%s\n' '{"bytes":524288,"event":"progress","file":"model.safetensors","model":"mlx-community/Qwen3.5-0.8B-MLX-4bit","total":1048576}'
          fi
          printf '%s\n' '{"bytes":1048576,"event":"progress","file":"model.safetensors","model":"mlx-community/Qwen3.5-0.8B-MLX-4bit","total":1048576}'
          printf '%s\n' '{"event":"verifying","model":"mlx-community/Qwen3.5-0.8B-MLX-4bit"}'
          : > "$machine/model-downloaded"
          printf '%s\n' '{"event":"done","model":"mlx-community/Qwen3.5-0.8B-MLX-4bit"}'
          exit 0
        fi

        if [ "$#" -eq 4 ] && [ "$1" = start ] && [ "$2" = --model ] && [ "$3" = "mlx-community/Qwen3.5-0.8B-MLX-4bit" ] && [ "$4" = --local-endpoint ]; then
          start_mode=$(mode start success)
          if [ "$start_mode" = failure ]; then
            echo "Provider start failed. Verify the model and retry." >&2
            exit 1
          fi
          now=$(/bin/date +%s)
          pid=\#(processIdentity.pid)
          process_start_time_micros=\#(processIdentity.startTimeMicros)
          /bin/mkdir -p "${state_file%/*}" "$local_dir"
          printf '%s\n' "{\"schema\":1,\"pid\":$pid,\"process_identity\":{\"pid\":$pid,\"start_time_micros\":$process_start_time_micros},\"version\":\"0.0.0-fresh-install-test\",\"written_at\":$now,\"started_at\":$now,\"trust\":{\"trust_level\":\"self_signed\",\"status\":\"pending\",\"reason\":\"Waiting for coordinator trust\",\"received_at\":$now},\"current_model\":\"mlx-community/Qwen3.5-0.8B-MLX-4bit\",\"warm_models\":[\"mlx-community/Qwen3.5-0.8B-MLX-4bit\"],\"inference_active\":true,\"stats\":{\"requests_served\":0,\"tokens_generated\":0,\"usage_gaps\":0},\"identity\":{\"provider_name\":\"Fresh Install Test Mac\",\"operator_address\":\"acct-test\"}}" > "$state_file"
          printf '%s\n' "{\"base_url\":\"http://127.0.0.1:18080/v1\",\"api_key\":\"fresh-install-test-only\",\"host\":\"127.0.0.1\",\"port\":18080,\"pid\":$pid,\"process_identity\":{\"pid\":$pid,\"start_time_micros\":$process_start_time_micros},\"version\":\"0.0.0-fresh-install-test\",\"updated_at\":\"1970-01-01T00:00:00Z\"}" > "$local_dir/local.json"
          exit 0
        fi

        echo "unexpected fresh-install CLI argv: $*" >&2
        exit 64
        """#
    }
}
