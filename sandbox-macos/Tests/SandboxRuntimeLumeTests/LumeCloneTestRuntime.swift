import Foundation

/// A bounded two-record native-runtime fixture. Real private source files and
/// APFS clones exercise ownership/evidence transitions without starting a VM.
enum LumeCloneTestRuntime {
    static let script = #"""
    #!/bin/sh
    set -eu
    root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    behavior="$(tr -d '\n' < "$root/behavior")"
    case "${1:-}" in
      --version) printf '%s\n' '0.5.3' ;;
      ls)
        if [ "$behavior" = block-first-list ] && [ ! -f "$root/list-started" ]; then
          : > "$root/list-started"
          attempt=0
          while [ ! -f "$root/list-continue" ] && [ "$attempt" -lt 300 ]; do
            /bin/sleep 0.01
            attempt=$((attempt + 1))
          done
          [ -f "$root/list-continue" ] || exit 74
        fi
        cpu="$(tr -d '\n' < "$root/observed-cpu-count")"
        memory="$(tr -d '\n' < "$root/observed-memory-bytes")"
        disk="$(tr -d '\n' < "$root/observed-disk-bytes")"
        state="$(tr -d '\n' < "$root/state")"
        separator=''
        printf '['
        for name in sandbox-failure-test qualification-clone; do
          if [ -d "$root/vms/$name" ]; then
            observed_cpu="$cpu"
            observed_state="$state"
            if [ "$name" = qualification-clone ]; then
              observed_state=stopped
              if [ -f "$root/vms/$name/fixture-cpu" ]; then observed_cpu="$(cat "$root/vms/$name/fixture-cpu")"; fi
              if [ -f "$root/vms/$name/fixture-memory" ]; then memory="$(cat "$root/vms/$name/fixture-memory")"; fi
              if [ "$behavior" = clone-resource-mismatch ]; then observed_cpu=5; fi
            fi
            printf '%s{"name":"%s","cpuCount":%s,"memorySize":%s,"diskSize":{"total":%s},"status":"%s","sshAvailable":false}' \
              "$separator" "$name" "$observed_cpu" "$memory" "$disk" "$observed_state"
            separator=','
          fi
        done
        printf ']\n'
        ;;
      clone)
        [ "$#" = 7 ] && [ "$2" = sandbox-failure-test ] && [ "$3" = qualification-clone ]
        [ "$4" = --source-storage ] && [ "$5" = "$root/vms" ]
        [ "$6" = --dest-storage ] && [ "$7" = "$root/vms" ]
        [ ! -e "$root/vms/qualification-clone" ]
        /bin/cp -cR "$root/vms/sandbox-failure-test" "$root/vms/qualification-clone"
        : > "$root/create-started"
        case "$behavior" in
          clone-fails-after-copy) exit 72 ;;
          clone-changes-source) printf x | /bin/dd of="$root/vms/sandbox-failure-test/disk.img" bs=1 count=1 conv=notrunc 2>/dev/null ;;
          clone-block-after-copy)
            attempt=0
            while [ ! -f "$root/clone-continue" ] && [ "$attempt" -lt 300 ]; do
              /bin/sleep 0.01
              attempt=$((attempt + 1))
            done
            [ -f "$root/clone-continue" ] || exit 73
            ;;
        esac
        ;;
      set)
        [ "$#" = 8 ] && [ "$2" = qualification-clone ]
        [ "$3" = --cpu ] && [ "$5" = --memory ] && [ "$7" = --storage ] && [ "$8" = "$root/vms" ]
        [ -d "$root/vms/qualification-clone" ]
        printf '%s\n' "$@" > "$root/set-arguments"
        if [ "$behavior" = clone-set-fails ]; then exit 75; fi
        if [ "$behavior" != clone-set-ignores ]; then
          printf '%s\n' "$4" > "$root/vms/qualification-clone/fixture-cpu"
          printf '%s\n' "${6%B}" > "$root/vms/qualification-clone/fixture-memory"
        fi
        ;;
      *) exit 64 ;;
    esac
    """#
}
