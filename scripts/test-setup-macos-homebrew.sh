#!/usr/bin/env bash
# Offline tests for existing Homebrew and installer cleanup after success/failure.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-homebrew.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

prefix="$TEST_ROOT/homebrew"
mkdir -p "$prefix/bin" "$TEST_ROOT/tools"
cat > "$prefix/bin/brew" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  shellenv)
    printf 'export HOMEBREW_PREFIX="%s";\n' "$prefix"
    printf 'export HOMEBREW_CELLAR="%s/Cellar";\n' "$prefix"
    printf 'export HOMEBREW_REPOSITORY="%s";\n' "$prefix"
    ;;
  --version) echo 'Homebrew 0.0.0-test' ;;
  *) echo "unexpected brew call: \$*" >&2; exit 1 ;;
esac
FAKE
# Any download means the script took the install path.
printf '#!/usr/bin/env bash\necho "curl must not run" >&2\nexit 1\n' > "$TEST_ROOT/tools/curl"
chmod +x "$prefix/bin/brew" "$TEST_ROOT/tools/curl"

github_path="$TEST_ROOT/github_path"
github_env="$TEST_ROOT/github_env"
: > "$github_path"
: > "$github_env"

env -u RUNNER_TEMP PATH="$prefix/bin:$TEST_ROOT/tools:$PATH" \
  GITHUB_PATH="$github_path" GITHUB_ENV="$github_env" \
  "$ROOT/scripts/setup-macos-homebrew.sh" >/dev/null

grep -Fxq "HOMEBREW_PREFIX=$prefix" "$github_env"
grep -Fxq "HOMEBREW_CELLAR=$prefix/Cellar" "$github_env"
grep -Fxq "HOMEBREW_REPOSITORY=$prefix" "$github_env"
grep -Fxq "$prefix/bin" "$github_path"
grep -Fxq "$prefix/sbin" "$github_path"

# Missing GitHub output files must fail before any other work.
if env -u GITHUB_ENV PATH="$prefix/bin:$TEST_ROOT/tools:$PATH" GITHUB_PATH="$github_path" \
  "$ROOT/scripts/setup-macos-homebrew.sh" >/dev/null 2>&1; then
  echo 'setup accepted a missing GITHUB_ENV' >&2
  exit 1
fi

# Exercise the real install function without touching system Homebrew. The
# installer exits in its own shell; cleanup runs after the function's locals
# have left scope. Include spaces and a quote in RUNNER_TEMP to pin escaping.
awk '/^if ! brew_bin=/{exit} {print}' "$ROOT/scripts/setup-macos-homebrew.sh" > "$TEST_ROOT/install-functions.sh"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$TEST_ROOT/tools/uname"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$TEST_ROOT/tools/shasum"
cat > "$TEST_ROOT/tools/curl" <<'FAKE'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    printf '#!/usr/bin/env bash\nexit %s\n' "$INSTALLER_EXIT" > "$2"
    printf '%s\n' "$2" > "$INSTALLER_RECORD"
    exit 0
  fi
  shift
done
exit 2
FAKE
chmod +x "$TEST_ROOT/tools/"{uname,shasum,curl}
for installer_exit in 0 23; do
  runner_temp="$TEST_ROOT/install '$installer_exit"
  mkdir -p "$runner_temp"
  installer_record="$TEST_ROOT/installer-$installer_exit"
  if PATH="$TEST_ROOT/tools:$PATH" RUNNER_TEMP="$runner_temp" \
    GITHUB_PATH="$github_path" GITHUB_ENV="$github_env" \
    INSTALLER_EXIT="$installer_exit" INSTALLER_RECORD="$installer_record" \
    bash -c 'source "$1"; install_brew' _ "$TEST_ROOT/install-functions.sh"; then
    actual_status=0
  else
    actual_status=$?
  fi
  test "$actual_status" -eq "$installer_exit"
  test ! -e "$(cat "$installer_record")"
done

echo 'setup-macos-homebrew: ok'
